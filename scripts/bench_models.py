#!/usr/bin/env python3
"""
Measure how fast each ChatGPT-plan model returns reply suggestions.

  .venv/bin/python scripts/bench_models.py

For each model: time to the first complete suggestion line and to the end,
three rounds each, using a realistic work-scene transcript. Prints a table
and the suggestions from the fastest model. Results also go to
runtime/bench_models.txt.
"""
from __future__ import annotations

import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from server import chatgpt_plan as cp  # noqa: E402
from server.suggest import INSTRUCTIONS, build_user_text, parse_line  # noqa: E402

TURNS = [
    {"who": "them", "text": "Hey, are you busy right now?"},
    {"who": "me", "text": "Not really. What do you need?"},
    {"who": "them", "text": "Could you move these products to aisle five before your break? "
                            "And can you stay until six thirty tonight?"},
]
ROUNDS = 3
OUT = ROOT / "runtime" / "bench_models.txt"
lines_out: list[str] = []


def log(s: str = "") -> None:
    print(s, flush=True)
    lines_out.append(s)


def run_once(model: str) -> tuple[float | None, float, list[dict[str, str]]]:
    text = build_user_text("work", TURNS)
    t0 = time.perf_counter()
    first = None
    buf = ""
    items: list[dict[str, str]] = []
    for delta in cp.stream_text(model=model, instructions=INSTRUCTIONS, user_text=text):
        buf += delta
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            item = parse_line(line)
            if item:
                items.append(item)
                if first is None:
                    first = time.perf_counter() - t0
    item = parse_line(buf)
    if item:
        items.append(item)
        if first is None:
            first = time.perf_counter() - t0
    return first, time.perf_counter() - t0, items


def main() -> int:
    models = [m["slug"] for m in cp.list_models()]
    log(f"EasyTalk 模型速度测试 {time.strftime('%Y-%m-%d %H:%M')}，每个模型 {ROUNDS} 轮")
    results = []
    samples: dict[str, list[dict[str, str]]] = {}
    for model in models:
        firsts, totals, err = [], [], None
        for _ in range(ROUNDS):
            try:
                first, total, items = run_once(model)
            except cp.ChatGPTPlanError as exc:
                err = str(exc)[:120]
                break
            if first is not None:
                firsts.append(first)
            totals.append(total)
            samples[model] = items
        if err:
            log(f"  {model:<16} 失败：{err}")
            continue
        f = statistics.median(firsts) if firsts else float("nan")
        t = statistics.median(totals)
        results.append((f, t, model))
        log(f"  {model:<16} 第一条建议 {f:5.2f}s   全部完成 {t:5.2f}s   条数 {len(samples[model])}")
    if not results:
        log("没有可用模型。")
        return 1
    results.sort()
    best = results[0][2]
    log("")
    log(f"最快：{best}")
    for i, item in enumerate(samples.get(best, []), 1):
        log(f"  {i}. {item['en']}  —  {item['zh']}")
    log("")
    log(f"设为默认：.venv/bin/python scripts/chatgpt_signin.py use {best}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines_out) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except cp.ChatGPTPlanError as exc:
        print(f"失败：{exc}", file=sys.stderr)
        raise SystemExit(1)
