"""EasyTalk web server (phase 1).

The phone page streams microphone audio straight to Soniox with a short-lived
temporary key minted here; this server never sees the audio. Reply
suggestions go through the owner's own ChatGPT plan (Sign in with ChatGPT).
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import threading
from collections import OrderedDict
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import chatgpt_plan as cp
from .keychain import PASSCODE_ACCOUNT, SONIOX_ACCOUNT, KeychainError, read_secret
from .suggest import INSTRUCTIONS, SCENES, build_user_text, parse_line

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "static"
COOKIE = "et_session"
COOKIE_MAX_AGE = 30 * 24 * 3600
SONIOX_TEMP_KEY_URL = "https://api.soniox.com/v1/auth/temporary-api-key"
SESSION_LIMIT_SECONDS = 3 * 3600
SONIOX_TTS_URL = "https://tts-rt.soniox.com/tts"
TTS_MODEL = "tts-rt-v2"
TTS_VOICE = os.environ.get("EASYTALK_TTS_VOICE", "Adrian")
TTS_MAX_CHARS = 300

app = FastAPI(title="EasyTalk", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=STATIC), name="static")


# ------------------------------------------------------------------ auth

def _session_token(passcode: str) -> str:
    return hmac.new(passcode.encode(), b"easytalk-session-v1", hashlib.sha256).hexdigest()


def _authed(request: Request) -> bool:
    cookie = request.cookies.get(COOKIE, "")
    if not cookie:
        return False
    try:
        expected = _session_token(read_secret(PASSCODE_ACCOUNT))
    except KeychainError:
        return False
    return hmac.compare_digest(cookie, expected)


def _require_auth(request: Request) -> None:
    if not _authed(request):
        raise HTTPException(status_code=401, detail="请先输入访问口令")


def _client_ip(request: Request) -> str:
    return (request.headers.get("cf-connecting-ip")
            or (request.client.host if request.client else "unknown"))


_failures: dict[str, list[float]] = {}
_FAIL_WINDOW = 15 * 60
_FAIL_LIMIT = 8


def _too_many_failures(ip: str) -> bool:
    now = time.time()
    recent = [t for t in _failures.get(ip, []) if now - t < _FAIL_WINDOW]
    _failures[ip] = recent
    return len(recent) >= _FAIL_LIMIT


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Permissions-Policy"] = "microphone=(self)"
    if request.url.path == "/" or request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-cache"
    return response


@app.get("/healthz")
async def healthz() -> dict[str, bool]:
    return {"ok": True}


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


@app.post("/api/login")
async def login(request: Request) -> JSONResponse:
    ip = _client_ip(request)
    if _too_many_failures(ip):
        raise HTTPException(status_code=429, detail="尝试次数太多，请 15 分钟后再试")
    try:
        body = await request.json()
    except ValueError:
        body = {}
    given = str((body or {}).get("passcode") or "")
    try:
        passcode = read_secret(PASSCODE_ACCOUNT)
    except KeychainError:
        raise HTTPException(status_code=503, detail="服务器还没有设置访问口令") from None
    if not given or not hmac.compare_digest(given.encode(), passcode.encode()):
        _failures.setdefault(ip, []).append(time.time())
        raise HTTPException(status_code=401, detail="口令不对")
    _failures.pop(ip, None)
    response = JSONResponse({"ok": True})
    secure = (request.headers.get("x-forwarded-proto") == "https"
              or request.url.scheme == "https")
    response.set_cookie(COOKIE, _session_token(passcode), max_age=COOKIE_MAX_AGE,
                        httponly=True, secure=secure, samesite="strict", path="/")
    return response


@app.post("/api/logout")
async def logout() -> JSONResponse:
    response = JSONResponse({"ok": True})
    response.delete_cookie(COOKIE, path="/")
    return response


@app.get("/api/status")
async def status(request: Request) -> dict[str, Any]:
    authed = _authed(request)
    return {"authed": authed, "scenes": list(SCENES) if authed else []}


# ------------------------------------------------------------------ Soniox

async def _create_soniox_temp_key() -> dict[str, Any]:
    api_key = read_secret(SONIOX_ACCOUNT)
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(
            SONIOX_TEMP_KEY_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={
                "usage_type": "transcribe_websocket",
                "expires_in_seconds": 60,
                "single_use": True,
                "max_session_duration_seconds": SESSION_LIMIT_SECONDS,
                "client_reference_id": "easytalk-web",
            },
        )
    try:
        data = resp.json()
    except ValueError:
        data = {}
    if not 200 <= resp.status_code < 300 or not data.get("api_key"):
        # Only Soniox's error fields are shown, never the raw body (it may hold a key).
        detail = (data.get("message") or data.get("error_message")
                  or data.get("error_type") or "未知错误")
        raise HTTPException(status_code=502,
                            detail=f"Soniox 临时 Key 申请失败（HTTP {resp.status_code}）：{str(detail)[:200]}")
    return {"api_key": data["api_key"], "expires_at": data.get("expires_at")}


@app.post("/api/soniox-key")
async def soniox_key(request: Request) -> dict[str, Any]:
    _require_auth(request)
    try:
        return await _create_soniox_temp_key()
    except KeychainError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="连不上 Soniox，请检查网络") from None


# ------------------------------------------------------------------ suggestions

_model_cache: dict[str, str] = {}


def _suggest_model() -> str:
    if "model" not in _model_cache:
        _model_cache["model"] = cp.configured_model()
    return _model_cache["model"]


def _friendly_error(exc: BaseException) -> str:
    if isinstance(exc, cp.SignInRequired):
        return "EasyTalk 还没连接 ChatGPT（或登录已失效），请在 Mac 上运行 scripts/chatgpt_signin.py"
    if isinstance(exc, cp.ChatGPTPlanError):
        if exc.status == 429 or (exc.code or "").startswith("subscription_sharing"):
            return "ChatGPT 套餐额度暂时用完了"
        return f"建议回复失败：{str(exc)[:160]}"
    return "建议回复失败，请稍后再试"


def _sse(data: dict[str, Any]) -> str:
    return "data: " + json.dumps(data, ensure_ascii=False) + "\n\n"


@app.post("/api/suggest")
async def suggest(request: Request) -> StreamingResponse:
    _require_auth(request)
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="bad json") from None
    scene = str(body.get("scene") or "daily")
    turns = body.get("turns") if isinstance(body.get("turns"), list) else []
    turns = [t for t in turns if isinstance(t, dict)]
    user_text = build_user_text(scene, turns)

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
    stop = threading.Event()

    def worker() -> None:
        try:
            model = _suggest_model()
            for delta in cp.stream_text(model=model, instructions=INSTRUCTIONS,
                                        user_text=user_text):
                if stop.is_set():
                    return
                loop.call_soon_threadsafe(queue.put_nowait, ("delta", delta))
            loop.call_soon_threadsafe(queue.put_nowait, ("end", model))
        except BaseException as exc:  # noqa: BLE001
            loop.call_soon_threadsafe(queue.put_nowait, ("error", exc))

    threading.Thread(target=worker, daemon=True).start()

    async def events():
        started = time.perf_counter()
        buf, index = "", 0
        try:
            while True:
                kind, value = await queue.get()
                if kind == "delta":
                    buf += value
                    while "\n" in buf:
                        line, buf = buf.split("\n", 1)
                        item = parse_line(line)
                        if item and index < 3:
                            yield _sse({"type": "suggestion", "index": index, **item,
                                        "ms": int((time.perf_counter() - started) * 1000)})
                            index += 1
                elif kind == "end":
                    item = parse_line(buf)
                    if item and index < 3:
                        yield _sse({"type": "suggestion", "index": index, **item,
                                    "ms": int((time.perf_counter() - started) * 1000)})
                    yield _sse({"type": "done", "model": value,
                                "ms": int((time.perf_counter() - started) * 1000)})
                    return
                else:
                    yield _sse({"type": "error", "message": _friendly_error(value)})
                    return
        finally:
            stop.set()

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ------------------------------------------------------------------ text-to-speech

_tts_cache: "OrderedDict[str, bytes]" = OrderedDict()
_TTS_CACHE_SIZE = 64


async def _soniox_tts(text: str) -> bytes:
    api_key = read_secret(SONIOX_ACCOUNT)
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.post(
            SONIOX_TTS_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"model": TTS_MODEL, "language": "en", "voice": TTS_VOICE,
                  "audio_format": "mp3", "text": text},
        )
    if not 200 <= resp.status_code < 300 or not resp.content:
        try:
            data = resp.json()
        except ValueError:
            data = {}
        detail = data.get("message") or data.get("error_message") or data.get("error_type") or "未知错误"
        raise HTTPException(status_code=502, detail=f"朗读失败（HTTP {resp.status_code}）：{str(detail)[:200]}")
    return resp.content


@app.post("/api/tts")
async def tts(request: Request) -> Response:
    _require_auth(request)
    try:
        body = await request.json()
    except ValueError:
        body = {}
    text = " ".join(str((body or {}).get("text") or "").split())[:TTS_MAX_CHARS]
    if not text:
        raise HTTPException(status_code=400, detail="没有要朗读的内容")
    audio = _tts_cache.get(text)
    if audio is None:
        try:
            audio = await _soniox_tts(text)
        except KeychainError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from None
        except httpx.HTTPError:
            raise HTTPException(status_code=502, detail="连不上 Soniox 朗读服务") from None
        _tts_cache[text] = audio
        while len(_tts_cache) > _TTS_CACHE_SIZE:
            _tts_cache.popitem(last=False)
    else:
        _tts_cache.move_to_end(text)
    return Response(content=audio, media_type="audio/mpeg",
                    headers={"Cache-Control": "private, max-age=86400"})
