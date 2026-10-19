import unittest
import json
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POLICIES = ROOT / "gateway" / "policies"


class GuardedDevelopmentPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dev_policy = ET.parse(POLICIES / "dev-openai.xml.tftpl").getroot()
        cls.global_gate = ET.parse(POLICIES / "global-dev-gate.xml.tftpl").getroot()
        cls.dev_source = (POLICIES / "dev-openai.xml.tftpl").read_text(encoding="utf-8")
        cls.openapi = json.loads((ROOT / "gateway" / "openapi-dev.json").read_text(encoding="utf-8"))
        cls.apim_source = (ROOT / "infra" / "terraform" / "apim.tf").read_text(encoding="utf-8")
        cls.adapter_source = (ROOT / "infra" / "terraform" / "dev-unified.tf").read_text(encoding="utf-8")
        cls.variables_source = (ROOT / "infra" / "terraform" / "variables.tf").read_text(encoding="utf-8")

    def test_policy_is_subscription_product_scoped(self):
        inbound = self.dev_policy.find("inbound")
        policy = ET.tostring(inbound, encoding="unicode")
        self.assertIn("context.Product.Id", policy)
        self.assertIn("${product_id}", policy)
        self.assertIn('subscription_required = true', self.apim_source)
        self.assertIn('header = "Ocp-Apim-Subscription-Key"', self.apim_source)
        self.assertIn('query  = "subscription-key"', self.apim_source)
        self.assertIn('subscriptions_limit   = 1', self.apim_source)
        self.assertIn('published             = true', self.apim_source)

    def test_only_bounded_plain_text_chat_is_accepted(self):
        conditions = " ".join(node.get("condition", "") for node in self.dev_policy.findall(".//when"))
        self.assertIn('p.Name == "model"', conditions)
        self.assertIn('item["content"].Type != JTokenType.String', conditions)
        self.assertIn("totalCharacters > 8000", conditions)
        self.assertIn('max-size="16384"', self.dev_source)
        self.assertIn('set-variable name="aiflux-request-json"', self.dev_source)
        self.assertNotIn('set-variable name="aiflux-request" value="@(context.Request.Body.As&lt;JObject&gt;', self.dev_source)
        self.assertIn("context.Request.Url.Query.Keys.Any", conditions)
        self.assertIn('set-query-parameter name="subscription-key" exists-action="delete"', self.dev_source)
        for unsupported in ("tools", "images", "structured output"):
            self.assertIn(unsupported, self.dev_source.lower())
        self.assertIn("streaming", self.dev_source.lower())
        self.assertNotIn('"stream"', self.openapi["paths"]["/chat/completions"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"])
        self.assertNotIn("text/event-stream", self.openapi["paths"]["/chat/completions"]["post"]["responses"]["200"]["content"])

    def test_adapter_allows_ten_sql_owned_team_subscriptions(self):
        self.assertIn('subscriptions_limit   = 10', self.adapter_source)
        self.assertIn('subscription_required = true', self.adapter_source)
        self.assertIn('approval_required     = true', self.adapter_source)

    def test_adapter_completion_ceiling_matches_catalog_and_schema(self):
        adapter = json.loads((ROOT / "gateway" / "openapi-dev-adapter.json").read_text())
        body = adapter["paths"]["/chat/completions"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(body["properties"]["max_completion_tokens"]["maximum"], 100000)
        self.assertIn("var.dev_unified_max_completion_tokens", self.adapter_source)
        self.assertIn("var.dev_unified_tpm_limit", self.adapter_source)
        catalog = json.loads((ROOT / "gateway" / "catalog" / "dev-models.json").read_text())
        self.assertTrue(all(model["max_completion_tokens"] == 100000
                            for model in catalog["models"] if model["enabled"]))

    def test_openapi_import_is_bounded_and_default_backend_is_non_routable(self):
        self.assertEqual(set(self.openapi["paths"]), {"/models", "/chat/completions"})
        self.assertEqual(self.openapi["servers"][0]["url"], "https://aiflux-disabled.invalid")
        body = self.openapi["paths"]["/chat/completions"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        self.assertFalse(body["additionalProperties"])
        self.assertEqual(set(body["required"]), {"model", "messages", "max_completion_tokens"})
        self.assertIn('content_format = "openapi+json"', self.apim_source)
        self.assertIn('service_url           = "https://aiflux-disabled.invalid"', self.apim_source)
        backend = self.dev_policy.find("./backend")
        self.assertEqual([child.tag for child in backend], ["retry"])
        self.assertEqual(backend.find("./retry/forward-request").get("timeout"), "${unified ? 240 : 45}")

    def test_only_buffered_transient_model_errors_are_retried_once(self):
        retry = self.dev_policy.find("./backend/retry")
        self.assertEqual(retry.get("count"), "1")
        self.assertEqual(retry.get("interval"), "1")
        self.assertNotIn("429", retry.get("condition"))
        self.assertNotIn("401", retry.get("condition"))
        self.assertNotIn("403", retry.get("condition"))
        self.assertEqual(retry.find("forward-request").get("buffer-request-body"), "true")
        self.assertEqual(retry.find("forward-request").get("buffer-response"), "true")
        self.assertEqual(len(retry.findall("./choose/when/set-backend-service")), 2)
        failed = next(node for node in self.dev_policy.findall("./outbound/choose/when") if "StatusCode >= 500" in node.get("condition", ""))
        self.assertEqual(failed.find("./return-response/set-status").get("code"), "503")

    def test_original_redacted_and_completion_safety_are_present(self):
        safety_policies = self.dev_policy.findall(".//llm-content-safety")
        self.assertEqual(len(safety_policies), 3)
        self.assertTrue(all(policy.get("backend-id") == "${safety_backend_id}" for policy in safety_policies))
        self.assertTrue(all(category.get("threshold") == "${safety_threshold}"
                            for policy in safety_policies
                            for category in policy.findall("./categories/category")))
        self.assertIn("dev_openai_content_safety_threshold != null", self.apim_source)
        self.assertIn("default     = null", self.variables_source)
        self.assertNotIn('threshold="4"', self.dev_source)
        self.assertIn('"Microsoft.ApiManagement/service/backends@2024-06-01-preview"', self.apim_source)
        self.assertIn('managedIdentity = {', self.apim_source)
        self.assertIn('resource = "https://cognitiveservices.azure.com"', self.apim_source)
        self.assertIn('clientId = azurerm_user_assigned_identity.identity["gateway"].client_id', self.apim_source)
        self.assertNotIn("X-Aiflux-Debug-", self.dev_source)

    def test_pii_and_model_auth_are_fail_closed_and_keys_are_not_forwarded(self):
        send_request = self.dev_policy.find(".//send-request")
        self.assertIsNotNone(send_request)
        self.assertEqual(send_request.get("ignore-error"), "false")
        self.assertEqual(send_request.find("authentication-managed-identity").get("ignore-error"), "false")
        deleted = {header.get("name") for header in self.dev_policy.findall(".//set-header[@exists-action='delete']")}
        self.assertTrue({"Authorization", "api-key", "Ocp-Apim-Subscription-Key"} <= deleted)
        self.assertIn("https://cognitiveservices.azure.com/", self.dev_source)
        self.assertNotIn('set-header name="x-aiflux-original-body" exists-action="override"', self.dev_source)
        self.assertIn("context.Request.Body.As&lt;string&gt;(preserveContent: true)", self.dev_source)

    def test_pii_batches_follow_synchronous_document_limit_and_preserve_global_ids(self):
        self.assertIn("%{ for batch in range(5)", self.dev_source)
        self.assertIn("Math.Min(${batch * 5 + 5}, messages.Count)", self.dev_source)
        self.assertIn("Math.Min(5, messages.Count - ${batch * 5})", self.dev_source)
        self.assertIn('var index = ${batch * 5};', self.dev_source)
        self.assertIn('document["id"] != index.ToString()', self.dev_source)
        self.assertIn('JArray.Parse((string)context.Variables["aiflux-redacted-documents"])', self.dev_source)
        self.assertNotIn('Headers.GetValueOrDefault("x-aiflux-pii-response"', self.dev_source)
        self.assertEqual(
            self.openapi["paths"]["/chat/completions"]["post"]["requestBody"]["content"]
            ["application/json"]["schema"]["properties"]["messages"]["maxItems"], 25,
        )

    def test_non_dev_apis_remain_globally_denied(self):
        gate = self.global_gate.find("./inbound/choose/when")
        self.assertIsNotNone(gate)
        self.assertIn('context.Request.OriginalUrl.Path == "/dev/v1/models"', gate.get("condition"))
        self.assertIn('context.Request.OriginalUrl.Path == "/dev/v1/chat/completions"', gate.get("condition"))
        self.assertIn("${enabled}", gate.get("condition"))
        self.assertIn("${unified_enabled}", gate.get("condition"))
        self.assertNotIn('== "/llm/v1/models"', gate.get("condition"))
        self.assertEqual(self.global_gate.findall(".//base"), [])
        self.assertIn("set-status", [node.tag for node in gate.iter()])
        self.assertIn("azapi_resource.dev_unified_policy]", self.apim_source)
        self.assertIn('format = "rawxml"', self.apim_source)

    def test_prompt_and_completion_body_logging_is_not_enabled(self):
        self.assertIn('category = "GatewayLlmLogs"', self.apim_source)
        self.assertIn('largeLanguageModel = { logs = "enabled" }', self.apim_source)
        self.assertNotIn('messages = "all"', self.apim_source)
        self.assertNotIn("maxSizeInBytes", self.apim_source)
        self.assertIn('category = "GatewayLogs"', self.apim_source)
        self.assertRegex(self.apim_source, r'verbosity\s*=\s*"information"')
        self.assertIn("percentage = 100", self.apim_source)

    def test_request_validation_and_auth_failures_have_specific_errors(self):
        validation = self.dev_policy.find(".//validate-content")
        self.assertEqual(validation.get("id"), "aiflux-request-validation")
        self.assertEqual(validation.find("content").get("validate-as"), "json")
        self.assertEqual(validation.find("content").get("action"), "prevent")
        for policy in (self.dev_policy, self.global_gate):
            auth = policy.find("./on-error/choose/when")
            self.assertIn("SubscriptionKeyNotFound", auth.get("condition"))
            self.assertIn("SubscriptionKeyInvalid", auth.get("condition"))
            self.assertEqual(auth.find("./return-response/set-status").get("code"), "401")
        errors = self.dev_policy.findall("./on-error/choose/when")
        self.assertIn("aiflux-request-validation", errors[1].get("condition"))
        self.assertEqual(errors[1].find("./return-response/set-status").get("code"), "400")
        self.assertEqual(errors[2].find("./return-response/set-status").get("code"), "429")
        self.assertIn("TokenLimitExceededAfterPrompt", errors[2].get("condition"))
        self.assertEqual(
            self.dev_policy.find(".//llm-token-limit").get("retry-after-variable-name"),
            "aiflux-token-retry-after",
        )

    def test_multiple_credentials_and_query_credentials_are_rejected(self):
        self.assertIn('subscription_required = true', self.apim_source)
        self.assertIn('context.Request.Headers.ContainsKey("Authorization")', self.dev_source)
        self.assertIn('code":"conflicting_credentials"', self.dev_source)
        self.assertIn('context.Request.Url.Query.Keys.Any()', self.dev_source)

    def test_rpm_and_token_counters_have_distinct_namespaces(self):
        rpm = self.dev_policy.find(".//rate-limit-by-key").get("counter-key")
        tpm = self.dev_policy.find(".//llm-token-limit").get("counter-key")
        self.assertNotEqual(rpm, tpm)
        self.assertIn('"rpm:"', rpm)
        self.assertIn('"tpm:"', tpm)

    def test_only_confirmed_native_safety_violation_is_mapped_to_403(self):
        violations = self.dev_policy.findall("./on-error/choose/when")
        rejection = next(
            node for node in violations if "ContentSafetyPolicyViolated" in node.get("condition", "")
        )
        self.assertEqual(rejection.find("./return-response/set-status").get("code"), "403")
        trace = rejection.find("trace")
        self.assertEqual(trace.get("source"), "aiflux")
        self.assertEqual(
            {node.get("name"): node.get("value") for node in trace.findall("metadata")},
            {"category": "ContentSafety", "action": "blocked"},
        )
        self.assertEqual(self.dev_policy.find("./on-error/return-response/set-status").get("code"), "503")
        self.assertNotIn("context.LastError.Message", self.dev_source)

    def test_anthropic_normalization_precedes_mandatory_output_safety(self):
        outbound = self.dev_policy.find("outbound")
        normalize = outbound.find(".//set-body[@id='aiflux-anthropic-normalization']")
        self.assertIsNotNone(normalize)
        safety = outbound.find(".//llm-content-safety")
        self.assertIsNotNone(safety)
        nodes = list(outbound.iter())
        self.assertLess(nodes.index(normalize), nodes.index(safety))
        self.assertEqual(outbound.findall(".//return-response")[-1].find("set-status").get("code"), "503")
        self.assertNotIn("AnthropicResponseShape", self.dev_source)
        self.assertNotIn("Inspecting Anthropic response block", self.dev_source)
        errors = self.dev_policy.findall("./on-error/choose/when")
        rejection = next(node for node in errors
                         if 'PolicyId == "aiflux-anthropic-normalization"' in node.get("condition", ""))
        self.assertEqual(rejection.find("./return-response/set-status").get("code"), "503")
        self.assertIn('"code":"provider_response_invalid"', rejection.find("./return-response/set-body").text)
        self.assertEqual(
            {node.get("name"): node.get("value") for node in rejection.findall("./trace/metadata")},
            {"category": "ProviderResponse", "action": "rejected"},
        )


if __name__ == "__main__":
    unittest.main()
