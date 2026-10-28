#!/usr/bin/env python3
"""
Connect EasyTalk to your own ChatGPT account (local, personal use).

  .venv/bin/python scripts/chatgpt_signin.py            # sign in (opens the browser)
  .venv/bin/python scripts/chatgpt_signin.py status     # show state
  .venv/bin/python scripts/chatgpt_signin.py models     # list models
  .venv/bin/python scripts/chatgpt_signin.py use <slug> # pick the model for suggestions
  .venv/bin/python scripts/chatgpt_signin.py signout

Tokens live only in the macOS Keychain item "com.edmondxu.easytalk.chatgpt-account";
they are never printed. This is a separate registration from CrossBorder AI and HereToBuy.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server import chatgpt_plan as cp  # noqa: E402


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "signin"
    store = cp.KeychainStore()

    if cmd == "signin":
        rec = cp.sign_in(store)
        print(f"已连接：{rec.email or rec.subject}")
        models = cp.list_models(store)
        print("可用模型：" + ", ".join(m["slug"] for m in models))
        return 0

    if cmd == "status":
        rec = store.load()
        if rec is None or not rec.has_tokens:
            print("未连接。运行：.venv/bin/python scripts/chatgpt_signin.py")
            return 1
        left = int((rec.expires_at or 0) - time.time())
        print(f"已连接：{rec.email or rec.subject}")
        print(f"access token 剩余 {max(left, 0)} 秒（会自动刷新）")
        print(f"套餐额度授权：{'是' if rec.plan_usage_granted else '否'}")
        return 0

    if cmd == "models":
        current = cp.configured_model(store)
        for m in cp.list_models(store):
            mark = "*" if m["slug"] == current else " "
            print(f"{mark} {m['slug']:<28} {m['display_name']}")
        return 0

    if cmd == "use" and len(argv) == 2:
        cp.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        cp.MODEL_CONFIG_PATH.write_text(argv[1] + "\n", encoding="utf-8")
        print(f"建议回复的模型已设为 {argv[1]}（重启服务后生效）")
        return 0

    if cmd == "signout":
        store.delete()
        print("已从钥匙串删除 EasyTalk 的 ChatGPT 登录。")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except cp.ChatGPTPlanError as exc:
        print(f"失败：{exc}", file=sys.stderr)
        raise SystemExit(1)
