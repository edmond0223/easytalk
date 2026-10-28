"""Prompt building and output parsing for reply suggestions."""
from __future__ import annotations

import re
from typing import Any

SCENES: dict[str, str] = {
    "work": "At work in a Canadian supermarket: talking with a supervisor, coworkers or customers.",
    "hospital": "At a clinic, hospital or pharmacy: talking with a doctor, nurse, receptionist or pharmacist.",
    "school": "At the child's school: talking with a teacher or school staff.",
    "shop": "Shopping or at a service counter: prices, questions, returns and exchanges.",
    "phone": "A phone call with a company, office or service provider.",
    "daily": "Everyday small talk with neighbours, friends or people nearby.",
}

INSTRUCTIONS = """You are EasyTalk, a live conversation helper for a Mandarin-speaking newcomer in Canada whose English is intermediate. They are in a real, spoken English conversation right now and will read your suggestions on their phone and say one out loud.

Write exactly 3 replies the user (ME) could say next.

Rules:
- Natural spoken Canadian English, simple everyday words, at most 14 words each. Short beats perfect.
- The 3 replies serve different purposes:
  1. The most likely direct answer, acceptance or acknowledgement.
  2. A polite alternative: decline, delay, set a condition, or offer another option.
  3. A short clarifying question about a specific detail THEM said (not a generic "please repeat").
- Do not invent facts about the user (names, times, amounts). Keep such details vague instead.
- If the last THEM turn is unclear or incomplete, make reply 1 a polite request to repeat or slow down.

Output format, exactly 3 lines and nothing else:
English reply ||| 简体中文意思"""

MAX_TURNS = 12
MAX_CHARS = 600
_NUMBERING = re.compile(r"^\s*(?:[-*•]|\d+[.)、:：]?)\s*")


def build_user_text(scene: str, turns: list[dict[str, Any]]) -> str:
    setting = SCENES.get(scene, SCENES["daily"])
    lines = []
    for turn in turns[-MAX_TURNS:]:
        who = "ME" if turn.get("who") == "me" else "THEM"
        text = " ".join(str(turn.get("text") or "").split())[:MAX_CHARS]
        if text:
            lines.append(f"{who}: {text}")
    transcript = "\n".join(lines) if lines else "(nothing yet)"
    return (f"Setting: {setting}\n\n"
            f"Transcript, oldest first (THEM = the other person, ME = the user):\n"
            f"{transcript}\n\n"
            f"Write 3 replies for ME to say next.")


def parse_line(line: str) -> dict[str, str] | None:
    line = line.strip().strip("`").strip()
    if not line or "|||" not in line:
        return None
    en, _, zh = line.partition("|||")
    en = _NUMBERING.sub("", en).strip().strip('"').strip()
    zh = zh.strip().strip('"').strip()
    if not en:
        return None
    return {"en": en, "zh": zh}
