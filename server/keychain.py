"""Read EasyTalk secrets from the macOS login Keychain (service com.edmondxu.easytalk)."""
from __future__ import annotations

import subprocess
import time

SERVICE = "com.edmondxu.easytalk"
SONIOX_ACCOUNT = "soniox-api-key"
PASSCODE_ACCOUNT = "access-passcode"

_cache: dict[str, tuple[float, str]] = {}
_TTL = 300.0


class KeychainError(RuntimeError):
    pass


def read_secret(account: str, *, service: str = SERVICE) -> str:
    """Return the secret; cached for a few minutes so rotating it needs no restart."""
    hit = _cache.get(account)
    if hit and time.time() - hit[0] < _TTL:
        return hit[1]
    proc = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True, text=True, check=False,
    )
    value = proc.stdout.strip()
    if proc.returncode != 0 or not value:
        raise KeychainError(f"钥匙串里没有找到 {service} / {account}")
    _cache[account] = (time.time(), value)
    return value


def clear_cache() -> None:
    _cache.clear()
