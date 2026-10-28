"""Server tests. Run: .venv/bin/python -m pytest -q"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import server.app as appmod  # noqa: E402
from server import chatgpt_plan as cp  # noqa: E402
from server.suggest import build_user_text, parse_line  # noqa: E402

SECRETS = {"access-passcode": "open-sesame", "soniox-api-key": "sk-test"}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setattr(appmod, "read_secret", lambda account: SECRETS[account])
    appmod._failures.clear()
    appmod._model_cache.clear()
    return TestClient(appmod.app)


def login(client):
    r = client.post("/api/login", json={"passcode": "open-sesame"})
    assert r.status_code == 200
    return r


def sse_events(text: str) -> list[dict]:
    return [json.loads(chunk[5:]) for chunk in text.split("\n\n") if chunk.startswith("data:")]


def test_index_and_health(client):
    assert client.get("/healthz").json() == {"ok": True}
    r = client.get("/")
    assert r.status_code == 200 and "EasyTalk" in r.text
    assert r.headers["permissions-policy"] == "microphone=(self)"


def test_login_flow(client):
    assert client.get("/api/status").json()["authed"] is False
    assert client.post("/api/login", json={"passcode": "nope"}).status_code == 401
    r = login(client)
    cookie = r.headers["set-cookie"]
    assert "HttpOnly" in cookie and "SameSite=strict" in cookie
    assert client.get("/api/status").json()["authed"] is True
    client.post("/api/logout")
    client.cookies.clear()
    assert client.get("/api/status").json()["authed"] is False


def test_secure_cookie_behind_tunnel(client):
    r = client.post("/api/login", json={"passcode": "open-sesame"},
                    headers={"x-forwarded-proto": "https"})
    assert "Secure" in r.headers["set-cookie"]


def test_login_throttle(client):
    for _ in range(appmod._FAIL_LIMIT):
        assert client.post("/api/login", json={"passcode": "x"}).status_code == 401
    assert client.post("/api/login", json={"passcode": "open-sesame"}).status_code == 429


def test_passcode_change_logs_out(client, monkeypatch):
    login(client)
    monkeypatch.setattr(appmod, "read_secret", lambda a: "new-passcode" if a == "access-passcode" else "k")
    assert client.get("/api/status").json()["authed"] is False


def test_protected_endpoints_need_login(client):
    assert client.post("/api/soniox-key").status_code == 401
    assert client.post("/api/suggest", json={}).status_code == 401


def test_soniox_key(client, monkeypatch):
    async def fake():
        return {"api_key": "snx_temp_abc", "expires_at": "2026-10-28T23:00:00Z"}
    monkeypatch.setattr(appmod, "_create_soniox_temp_key", fake)
    login(client)
    assert client.post("/api/soniox-key").json()["api_key"] == "snx_temp_abc"


def test_soniox_request_shape(client, monkeypatch):
    seen = {}

    class FakeResp:
        status_code = 201  # Soniox answers 201 Created
        def json(self):
            return {"api_key": "snx_temp_x", "expires_at": "t"}

    class FakeClient:
        def __init__(self, *a, **k): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def post(self, url, headers=None, json=None):
            seen.update(url=url, headers=headers, json=json)
            return FakeResp()

    monkeypatch.setattr(appmod.httpx, "AsyncClient", FakeClient)
    login(client)
    assert client.post("/api/soniox-key").json()["api_key"] == "snx_temp_x"
    assert seen["url"] == "https://api.soniox.com/v1/auth/temporary-api-key"
    assert seen["headers"]["Authorization"] == "Bearer sk-test"
    assert seen["json"]["usage_type"] == "transcribe_websocket"
    assert seen["json"]["single_use"] is True
    assert seen["json"]["expires_in_seconds"] == 60


def test_suggest_streams_parsed_lines(client, monkeypatch):
    captured = {}

    def fake_stream(*, model, instructions, user_text, **kw):
        captured.update(model=model, user_text=user_text)
        yield "1. Sure, I can do"
        yield " that before my break. ||| 好的，我休息前做。\n2. Can I do it after"
        yield " my break? ||| 我休息后做可以吗？\n"
        yield "Which products? ||| 哪些商品？"

    monkeypatch.setattr(appmod.cp, "stream_text", fake_stream)
    monkeypatch.setattr(appmod, "_suggest_model", lambda: "gpt-test")
    login(client)
    r = client.post("/api/suggest", json={"scene": "work", "turns": [
        {"who": "them", "text": "Could you move these to aisle five?"}]})
    events = sse_events(r.text)
    sugs = [e for e in events if e["type"] == "suggestion"]
    assert [s["en"] for s in sugs] == [
        "Sure, I can do that before my break.", "Can I do it after my break?", "Which products?"]
    assert sugs[1]["zh"] == "我休息后做可以吗？"
    assert events[-1]["type"] == "done" and events[-1]["model"] == "gpt-test"
    assert "THEM: Could you move these to aisle five?" in captured["user_text"]
    assert "supermarket" in captured["user_text"]


def test_suggest_sign_in_error_is_friendly(client, monkeypatch):
    def boom(**kw):
        raise cp.SignInRequired("HTTP 401")
        yield  # pragma: no cover
    monkeypatch.setattr(appmod.cp, "stream_text", boom)
    monkeypatch.setattr(appmod, "_suggest_model", lambda: "gpt-test")
    login(client)
    events = sse_events(client.post("/api/suggest", json={"turns": []}).text)
    assert events[-1]["type"] == "error"
    assert "chatgpt_signin.py" in events[-1]["message"]


def test_parse_line_and_prompt():
    assert parse_line("1. Sure! ||| 当然！") == {"en": "Sure!", "zh": "当然！"}
    assert parse_line("- \"Okay\" ||| 好") == {"en": "Okay", "zh": "好"}
    assert parse_line("no separator") is None
    assert parse_line("   ") is None
    text = build_user_text("unknown-scene", [{"who": "me", "text": "Hi"}, {"who": "x", "text": "  Hello   there "}])
    assert "ME: Hi" in text and "THEM: Hello there" in text
    long_turns = [{"who": "them", "text": f"t{i}"} for i in range(30)]
    assert "t17" not in build_user_text("work", long_turns) and "t29" in build_user_text("work", long_turns)


def test_stream_text_parses_sse(monkeypatch):
    class FakeResp:
        def __init__(self, lines): self.lines = lines
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def __iter__(self): return iter(self.lines)

    lines = [b'event: x\n',
             b'data: {"type":"response.output_text.delta","delta":"Hi"}\n',
             b'data: {"type":"response.output_text.delta","delta":" there"}\n',
             b'data: {"type":"response.completed","response":{}}\n']
    monkeypatch.setattr(cp, "valid_access_token", lambda store=None, rejected_token=None: "tok")
    monkeypatch.setattr(cp.urllib.request, "urlopen", lambda req, timeout=60: FakeResp(lines))
    assert "".join(cp.stream_text(model="m", instructions="i", user_text="u")) == "Hi there"


def test_soniox_error_does_not_echo_body(client, monkeypatch):
    class FakeResp:
        status_code = 401
        text = '{"api_key":"should-not-leak","message":"Incorrect API key provided."}'
        def json(self):
            return {"api_key": "should-not-leak", "message": "Incorrect API key provided."}

    class FakeClient:
        def __init__(self, *a, **k): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def post(self, *a, **k): return FakeResp()

    monkeypatch.setattr(appmod.httpx, "AsyncClient", FakeClient)
    login(client)
    r = client.post("/api/soniox-key")
    assert r.status_code == 502
    assert "Incorrect API key" in r.json()["detail"]
    assert "should-not-leak" not in r.text
