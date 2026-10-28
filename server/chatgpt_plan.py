"""
ChatGPT plan usage for EasyTalk ("Sign in with ChatGPT", local personal use).

Adapted from HereToBuy's module. The user's own ChatGPT account signs in once
from this Mac (scripts/chatgpt_signin.py). The OAuth token set is kept in the macOS
Keychain and never leaves this Mac except as the Bearer token sent to
https://api.openai.com/v1 (public Responses API).

This is a separate registration from CrossBorder AI and HereToBuy: its own
client_id, host id and Keychain item. Sharing one token set between two
apps would break both, because refresh tokens rotate and reuse is fatal.

Only stdlib is used.
"""
from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import http.server
import json
import os
import secrets
import socketserver
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

# ---------------------------------------------------------------- config

AUTHORIZE_URL = "https://auth.openai.com/api/accounts/authorize"
TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
DISCOVERY_URL = "https://auth.openai.com/.well-known/openid-configuration"
API_BASE = "https://api.openai.com/v1"
RESOURCE = "https://api.openai.com/v1"

REGISTRATION_CLIENT_ID = "dynamic_agent_client"
AGENT_NAME_HINT = "EasyTalk"
SCOPE = (
    "openid profile email offline_access resource.invoke "
    "chatgpt.tokens.use.direct"
)
PLAN_SCOPE = "chatgpt.tokens.use.direct"
CALLBACK_PATH = "/auth/callback"
CALLBACK_PORTS = (1455, 1456, 1457)
CALLBACK_TIMEOUT = 300.0

REFRESH_LEEWAY = 120.0
TERMINAL_REFRESH_ERRORS = {
    "invalid_grant",
    "invalid_refresh_token",
    "refresh_token_expired",
    "refresh_token_invalidated",
    "refresh_token_reused",
}

KEYCHAIN_SERVICE = "com.edmondxu.easytalk.chatgpt-account"
KEYCHAIN_ACCOUNT = "default"

CONFIG_DIR = Path.home() / ".config" / "easytalk"
LOCK_PATH = CONFIG_DIR / "chatgpt_plan.lock"
MODEL_CONFIG_PATH = CONFIG_DIR / "chatgpt_model"


class ChatGPTPlanError(RuntimeError):
    def __init__(self, message: str, *, code: str | None = None,
                 status: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


class SignInRequired(ChatGPTPlanError):
    pass


# ---------------------------------------------------------------- record

@dataclass
class CredentialRecord:
    client_id: str
    ext_agent_host_id: str
    email: str | None = None
    subject: str | None = None
    issuer: str | None = None
    id_token: str | None = None
    access_token: str | None = None
    refresh_token: str | None = None
    token_type: str | None = None
    expires_at: float | None = None
    scopes: list[str] = field(default_factory=list)
    saved_at: float | None = None

    @property
    def has_tokens(self) -> bool:
        return bool(self.access_token) and bool(self.refresh_token)

    @property
    def plan_usage_granted(self) -> bool:
        return PLAN_SCOPE in self.scopes

    def clearing_tokens(self) -> "CredentialRecord":
        data = asdict(self)
        data.update(id_token=None, access_token=None, refresh_token=None,
                    token_type=None, expires_at=None)
        return CredentialRecord(**data)


class KeychainStore:
    """One generic-password item; value is the JSON record."""

    def __init__(self, service: str = KEYCHAIN_SERVICE,
                 account: str = KEYCHAIN_ACCOUNT) -> None:
        self.service = service
        self.account = account

    def load(self) -> CredentialRecord | None:
        proc = subprocess.run(
            ["security", "find-generic-password",
             "-s", self.service, "-a", self.account, "-w"],
            capture_output=True, text=True, check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        try:
            data = json.loads(proc.stdout.strip())
            known = CredentialRecord.__dataclass_fields__
            return CredentialRecord(**{k: v for k, v in data.items() if k in known})
        except (ValueError, TypeError):
            return None

    def save(self, record: CredentialRecord) -> None:
        record.saved_at = time.time()
        payload = json.dumps(asdict(record), separators=(",", ":"))
        proc = subprocess.run(
            ["security", "add-generic-password", "-U",
             "-s", self.service, "-a", self.account,
             "-l", "EasyTalk ChatGPT account", "-w", payload],
            capture_output=True, text=True, check=False,
        )
        if proc.returncode != 0:
            raise ChatGPTPlanError(
                f"macOS Keychain save failed (exit {proc.returncode})")

    def delete(self) -> None:
        subprocess.run(
            ["security", "delete-generic-password",
             "-s", self.service, "-a", self.account],
            capture_output=True, text=True, check=False,
        )


# ---------------------------------------------------------------- helpers

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def random_token(nbytes: int = 32) -> str:
    return b64url(secrets.token_bytes(nbytes))


def new_host_id() -> str:
    """The authorize endpoint requires a URN UUID (urn:uuid:<lowercase uuid>)."""
    return "urn:uuid:" + str(uuid.uuid4())


def is_valid_host_id(value: str | None) -> bool:
    if not value or not value.startswith("urn:uuid:"):
        return False
    try:
        return str(uuid.UUID(value[9:])) == value[9:]
    except ValueError:
        return False


def pkce_challenge(verifier: str) -> str:
    return b64url(hashlib.sha256(verifier.encode()).digest())


def _post_form(url: str, fields: Iterable[tuple[str, str]],
               timeout: float = 30) -> tuple[int, dict[str, Any]]:
    body = urllib.parse.urlencode(list(fields)).encode()
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw or b"{}")
        except ValueError:
            return exc.code, {"error": "http_error",
                              "error_description": raw[:300].decode("utf-8", "replace")}


def _get_json(url: str, *, token: str | None = None,
              timeout: float = 20) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise _http_error(exc.code, exc.read()) from None


def _http_error(status: int, body: bytes) -> ChatGPTPlanError:
    code = None
    message = body[:500].decode("utf-8", "replace")
    try:
        data = json.loads(body)
        err = data.get("error")
        if isinstance(err, dict):
            code = err.get("code") or err.get("type")
            message = err.get("message") or message
        elif isinstance(err, str):
            code = err
            message = data.get("error_description") or message
    except ValueError:
        pass
    cls = SignInRequired if status == 401 else ChatGPTPlanError
    return cls(f"HTTP {status} {code or ''} {message}".strip(),
               code=code, status=status)


def decode_jwt_claims(token: str) -> dict[str, Any]:
    try:
        return json.loads(b64url_decode(token.split(".")[1]))
    except (IndexError, ValueError) as exc:
        raise ChatGPTPlanError("id_token is not a JWT") from exc


def check_id_token(claims: dict[str, Any], *, issuer: str,
                   client_id: str, nonce: str | None,
                   now: float | None = None) -> None:
    """
    Claim checks for an id_token received directly from the token
    endpoint over TLS (OIDC Core 3.1.3.7: TLS server validation may
    replace signature validation for this back-channel response).
    """
    now = time.time() if now is None else now
    if claims.get("iss") != issuer:
        raise ChatGPTPlanError("id_token issuer mismatch")
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if client_id not in auds:
        raise ChatGPTPlanError("id_token audience mismatch")
    if nonce is not None and claims.get("nonce") != nonce:
        raise ChatGPTPlanError("id_token nonce mismatch")
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or exp + 5 < now:
        raise ChatGPTPlanError("id_token expired")
    if not claims.get("sub"):
        raise ChatGPTPlanError("id_token has no subject")


# ---------------------------------------------------------------- sign-in

class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    result: dict[str, str] | None = None
    done: threading.Event

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != CALLBACK_PATH:
            self.send_response(404)
            self.end_headers()
            return
        params = dict(urllib.parse.parse_qsl(parsed.query))
        type(self).result = params
        ok = "code" in params and "error" not in params
        text = ("EasyTalk 已连接 ChatGPT，可以关闭此页面。" if ok
                else "ChatGPT 登录没有完成，请回到终端查看提示。")
        body = (f"<!doctype html><meta charset=utf-8><title>EasyTalk</title>"
                f"<p style='font-family:-apple-system,sans-serif;padding:48px;"
                f"text-align:center'>{text}</p>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        type(self).done.set()

    def log_message(self, *args: Any) -> None:  # keep codes out of logs
        return


def sign_in(store: KeychainStore | None = None, *,
            open_browser: bool = True, timeout: float = CALLBACK_TIMEOUT
            ) -> CredentialRecord:
    store = store or KeychainStore()
    existing = store.load()
    host_id = (existing.ext_agent_host_id
               if existing and is_valid_host_id(existing.ext_agent_host_id)
               else new_host_id())
    discovery = _get_json(DISCOVERY_URL)
    issuer = discovery["issuer"]

    handler = type("Handler", (_CallbackHandler,), {
        "result": None, "done": threading.Event()})
    server = None
    for port in CALLBACK_PORTS:
        try:
            server = socketserver.TCPServer(("127.0.0.1", port), handler)
            break
        except OSError:
            continue
    if server is None:
        raise ChatGPTPlanError("ports 1455-1457 are all busy")
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        redirect_uri = f"http://127.0.0.1:{port}{CALLBACK_PATH}"
        state, nonce, verifier = random_token(), random_token(), random_token()
        pending_client = existing.client_id if existing else REGISTRATION_CLIENT_ID
        query: list[tuple[str, str]] = [("client_id", pending_client)]
        if existing is None:
            query.append(("agent_name_hint", AGENT_NAME_HINT))
        query.append(("ext_agent_host_id", host_id))
        if existing and existing.email:
            query.append(("login_hint", existing.email))
        query += [
            ("response_type", "code"),
            ("redirect_uri", redirect_uri),
            ("scope", SCOPE),
            ("resource", RESOURCE),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", pkce_challenge(verifier)),
        ]
        url = AUTHORIZE_URL + "?" + urllib.parse.urlencode(
            query, quote_via=urllib.parse.quote)
        print("在浏览器里登录 ChatGPT 并同意授权……")
        if not (open_browser and webbrowser.open(url)):
            print("请手动打开这个链接：\n" + url)

        if not handler.done.wait(timeout):
            raise ChatGPTPlanError("等待浏览器回调超时")
        cb = handler.result or {}
    finally:
        server.shutdown()
        server.server_close()

    if cb.get("state") != state:
        raise ChatGPTPlanError("state mismatch")
    if cb.get("error"):
        raise ChatGPTPlanError(
            f"authorization failed: {cb['error']} {cb.get('error_description', '')}")
    code = cb.get("code")
    if not code:
        raise ChatGPTPlanError("callback has no authorization code")

    if existing:
        returned = cb.get("client_id")
        if returned and returned != existing.client_id:
            raise ChatGPTPlanError("client_id mismatch")
        client_id = existing.client_id
    else:
        client_id = cb.get("client_id") or ""
        if not client_id or client_id == REGISTRATION_CLIENT_ID:
            raise ChatGPTPlanError("callback did not return the issued client_id")
        store.save(CredentialRecord(client_id=client_id,
                                    ext_agent_host_id=host_id))

    status, token = _post_form(TOKEN_URL, [
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", redirect_uri),
        ("resource", RESOURCE),
    ])
    if not 200 <= status < 300:
        raise ChatGPTPlanError(
            f"token exchange failed: HTTP {status} {token.get('error', '')}")
    id_token = token.get("id_token")
    if not id_token:
        raise ChatGPTPlanError("token response has no id_token")
    claims = decode_jwt_claims(id_token)
    check_id_token(claims, issuer=issuer, client_id=client_id, nonce=nonce)
    if existing and existing.subject and existing.subject != claims["sub"]:
        raise ChatGPTPlanError("signed in with a different ChatGPT account")

    record = CredentialRecord(
        client_id=client_id,
        ext_agent_host_id=host_id,
        email=claims.get("email") or (existing.email if existing else None),
        subject=claims["sub"],
        issuer=issuer,
        id_token=id_token,
        access_token=token.get("access_token"),
        refresh_token=token.get("refresh_token"),
        token_type=token.get("token_type"),
        expires_at=time.time() + float(token.get("expires_in") or 3600),
        scopes=(token.get("scope") or cb.get("scope") or "").split(),
    )
    if not record.refresh_token:
        store.save(record.clearing_tokens())
        raise ChatGPTPlanError("no refresh token returned (offline_access)")
    if not record.plan_usage_granted:
        store.save(record.clearing_tokens())
        raise ChatGPTPlanError("ChatGPT plan usage was not granted")
    store.save(record)
    return record


# ---------------------------------------------------------------- tokens

_thread_lock = threading.Lock()


@contextlib.contextmanager
def _refresh_lock():
    """Serialize refreshes across threads AND processes (the server and
    the helper scripts may run at once; refresh tokens rotate)."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with _thread_lock:
        with open(LOCK_PATH, "a+") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)


def valid_access_token(store: KeychainStore | None = None, *,
                       rejected_token: str | None = None) -> str:
    """
    Return a usable access token, refreshing when it is near expiry or
    when the caller reports `rejected_token` was refused (HTTP 401).
    """
    store = store or KeychainStore()
    with _refresh_lock():
        rec = store.load()
        if rec is None or not rec.has_tokens:
            raise SignInRequired(
                "EasyTalk 还没有连接 ChatGPT，请先运行 scripts/chatgpt_signin.py")
        fresh = (rec.expires_at or 0) - time.time() > REFRESH_LEEWAY
        if fresh and rec.access_token != rejected_token:
            return rec.access_token  # type: ignore[return-value]

        status, token = _post_form(TOKEN_URL, [
            ("grant_type", "refresh_token"),
            ("client_id", rec.client_id),
            ("refresh_token", rec.refresh_token or ""),
            ("resource", RESOURCE),
        ])
        if not 200 <= status < 300:
            code = token.get("error")
            if code in TERMINAL_REFRESH_ERRORS:
                store.save(rec.clearing_tokens())
                raise SignInRequired(
                    "ChatGPT 登录已失效，请重新运行 scripts/chatgpt_signin.py")
            raise ChatGPTPlanError(f"token refresh failed: HTTP {status} {code or ''}")

        rec.access_token = token.get("access_token")
        if token.get("refresh_token"):
            rec.refresh_token = token["refresh_token"]
        if token.get("id_token"):
            rec.id_token = token["id_token"]
        if token.get("token_type"):
            rec.token_type = token["token_type"]
        rec.expires_at = time.time() + float(token.get("expires_in") or 3600)
        if token.get("scope"):
            rec.scopes = token["scope"].split()
        store.save(rec)
        return rec.access_token  # type: ignore[return-value]


# ---------------------------------------------------------------- API

def parse_models(data: dict[str, Any]) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    for entry in data.get("models") or data.get("data") or []:
        slug = entry.get("slug") or entry.get("id")
        if not slug or slug in seen:
            continue
        if "visibility" in entry and entry.get("visibility") != "list":
            continue
        seen.add(slug)
        out.append({"slug": slug,
                    "display_name": (entry.get("display_name") or slug).strip()})
    return out


def list_models(store: KeychainStore | None = None) -> list[dict[str, str]]:
    token = valid_access_token(store)
    try:
        return parse_models(_get_json(f"{API_BASE}/models", token=token))
    except SignInRequired:
        token = valid_access_token(store, rejected_token=token)
        return parse_models(_get_json(f"{API_BASE}/models", token=token))


def configured_model(store: KeychainStore | None = None) -> str:
    env = os.getenv("EASYTALK_CHATGPT_MODEL", "").strip()
    if env:
        return env
    if MODEL_CONFIG_PATH.is_file():
        saved = MODEL_CONFIG_PATH.read_text(encoding="utf-8").strip()
        if saved:
            return saved
    models = list_models(store)
    if not models:
        raise ChatGPTPlanError("no models available on this ChatGPT plan")
    return models[0]["slug"]


@dataclass
class StreamResult:
    text: str
    usage: dict[str, Any] | None
    completed: bool


def parse_sse(lines: Iterable[bytes]) -> StreamResult:
    """Collect output text from a Responses API event stream."""
    chunks: list[str] = []
    usage = None
    completed = False
    final_text = None
    for raw in lines:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            event = json.loads(payload)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "response.output_text.delta":
            chunks.append(event.get("delta") or "")
        elif kind == "response.output_text.done":
            final_text = event.get("text")
        elif kind == "response.completed":
            completed = True
            usage = (event.get("response") or {}).get("usage")
        elif kind == "response.failed":
            err = ((event.get("response") or {}).get("error") or {})
            raise ChatGPTPlanError(
                f"response failed: {err.get('message', '')}", code=err.get("code"))
        elif kind == "response.incomplete":
            details = (event.get("response") or {}).get("incomplete_details") or {}
            raise ChatGPTPlanError(
                f"response incomplete: {details.get('reason', 'unknown')}")
        elif kind == "error":
            err = event.get("error") or event
            raise ChatGPTPlanError(
                f"stream error: {err.get('message', '')}", code=err.get("code"))
    text = "".join(chunks)
    if final_text and len(final_text) >= len(text):
        text = final_text
    return StreamResult(text=text, usage=usage, completed=completed)


def stream_text(*, model: str, instructions: str, user_text: str,
                store: KeychainStore | None = None,
                extra: dict[str, Any] | None = None,
                timeout: float = 60):
    """
    Stream a text-only Responses API call. Yields text deltas as they
    arrive. Raises ChatGPTPlanError on failure. Retries once on 401.
    """
    body: dict[str, Any] = {
        "model": model,
        "instructions": instructions,
        "input": [{"role": "user", "content": user_text}],
        "store": False,
        "stream": True,
    }
    if extra:
        body.update(extra)
    token = valid_access_token(store)
    for attempt in (1, 2):
        req = urllib.request.Request(
            f"{API_BASE}/responses",
            data=json.dumps(body).encode(), method="POST",
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json",
                     "Accept": "text/event-stream"},
        )
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as exc:
            err = _http_error(exc.code, exc.read())
            if err.status == 401 and attempt == 1:
                token = valid_access_token(store, rejected_token=token)
                continue
            raise err from None
        with resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    return
                try:
                    event = json.loads(payload)
                except ValueError:
                    continue
                kind = event.get("type")
                if kind == "response.output_text.delta":
                    delta = event.get("delta") or ""
                    if delta:
                        yield delta
                elif kind == "response.completed":
                    return
                elif kind in ("response.failed", "error"):
                    err = ((event.get("response") or {}).get("error")
                           or event.get("error") or {})
                    raise ChatGPTPlanError(
                        f"response failed: {err.get('message', '')}",
                        code=err.get("code"))
                elif kind == "response.incomplete":
                    details = (event.get("response") or {}).get("incomplete_details") or {}
                    raise ChatGPTPlanError(
                        f"response incomplete: {details.get('reason', 'unknown')}")
            return
