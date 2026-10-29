#!/usr/bin/env python3
"""Start EasyTalk on 127.0.0.1 (Cloudflare Tunnel forwards https://easytalk.example.com here)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import uvicorn

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.chdir(ROOT)

if __name__ == "__main__":
    uvicorn.run(
        "server.app:app",
        host="127.0.0.1",
        port=int(os.environ.get("EASYTALK_PORT", "8791")),
        proxy_headers=True,
        forwarded_allow_ips="127.0.0.1",
        log_level="info",
    )
