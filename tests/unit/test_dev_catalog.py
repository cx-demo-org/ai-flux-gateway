import json
from pathlib import Path

import pytest
from aiflux.catalog import Catalog


def test_dev_catalog_keeps_placeholders_uncallable():
    catalog = Catalog.load(Path(__file__).resolve().parents[2] / "gateway/catalog/dev-models.json")
    assert {m.id for m in catalog.models if m.enabled} == {"gpt-5-nano"}
    assert len([m for m in catalog.models if m.placeholder]) == 6
    assert all(not m.enabled and not m.capabilities for m in catalog.models if m.placeholder)
    assert all(m.max_completion_tokens == 100000 and m.capabilities == ["chat"]
               for m in catalog.models if m.enabled)


def test_enabled_placeholder_is_rejected(tmp_path):
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps({"models": [{
        "id": "preview", "provider": "OpenAI", "capabilities": [], "enabled": True, "placeholder": True,
    }]}))
    with pytest.raises(ValueError, match="placeholders cannot be enabled"):
        Catalog.load(path)


def test_catalog_api_exposes_preview_without_enabling_it(env):
    env.settings.catalog_path = Path(__file__).resolve().parents[2] / "gateway/catalog/dev-models.json"
    response = env.client.get("/api/models", headers=env.customer)
    assert response.status_code == 200
    items = response.json()["items"]
    assert len(items) == 7
    assert len([m for m in items if m["enabled"]]) == 1
    assert len([m for m in items if m["placeholder"] and not m["enabled"]]) == 6
    assert all(m["max_completion_tokens"] == 100000 for m in items if m["enabled"])


def test_catalog_api_never_advertises_more_than_configured_gateway_limit(env):
    env.settings.catalog_path = Path(__file__).resolve().parents[2] / "gateway/catalog/dev-models.json"
    env.settings.gateway_max_completion_tokens = 50000
    response = env.client.get("/api/models", headers=env.customer)
    assert response.status_code == 200
    assert all(model["max_completion_tokens"] == 50000
               for model in response.json()["items"] if model["enabled"])
