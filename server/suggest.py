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

LANGS: dict[str, str] = {
    "zh": "Simplified Chinese (Mandarin)",
    "en": "Canadian English",
    "fr": "Canadian French",
}


def lang_pair(mine: object, theirs: object) -> tuple[str, str]:
    """Validated (mine, theirs) language codes; defaults zh / en."""
    m = mine if mine in LANGS else "zh"
    t = theirs if theirs in LANGS else "en"
    if t == m:
        t = "zh" if m == "en" else "en"
    return m, t  # type: ignore[return-value]


def instructions(mine: str = "zh", theirs: str = "en") -> str:
    me, them = LANGS[mine], LANGS[theirs]
    return f"""You are EasyTalk, a live conversation helper for a newcomer in Canada. The user (ME) speaks {me} natively and is in a real, spoken conversation in {them} right now. They will read your suggestions on their phone and say one out loud.

Write exactly 3 replies ME could say next, in {them}.

Rules:
- Natural spoken {them}, simple everyday words, at most 14 words each. Short beats perfect.
- The 3 replies serve different purposes:
  1. The most likely direct answer, acceptance or acknowledgement.
  2. A polite alternative: decline, delay, set a condition, or offer another option.
  3. A short clarifying question about a specific detail THEM said (not a generic "please repeat").
- Do not invent facts about the user (names, times, amounts). Keep such details vague instead.
- If the last THEM turn is unclear or incomplete, make reply 1 a polite request to repeat or slow down.
- ME may have spoken in either language; THEM lines may be in either language too.

Output format, exactly 3 lines and nothing else:
reply in {them} ||| meaning in {me}"""


INSTRUCTIONS = instructions()


def polish_instructions(source: str, target: str) -> str:
    return f"""You translate live speech captions from {LANGS[source]} into natural, fluent {LANGS[target]}. The reader is a newcomer living in Canada.

Rules:
- Translate only the text under TRANSLATE. Earlier lines are context only; never translate or repeat them.
- Keep the meaning exact, especially numbers, times, dates, amounts, names and places.
- Natural spoken language, not word-for-word. Keep names and brands as they are when there is no common translation.
- The text comes from speech recognition and may contain small errors; translate the most likely intended meaning.
- Use the glossary translations when those terms appear.
- Output only the {LANGS[target]} translation, nothing else."""


def build_polish_text(setting: str, glossary: list[dict[str, Any]], context: list[str], text: str) -> str:
    parts = [f"Setting: {setting}"]
    lines = [f"{g.get('source')} = {g.get('target')}" for g in glossary[:60]
             if isinstance(g, dict) and g.get("source") and g.get("target")]
    if lines:
        parts.append("Glossary:\n" + "\n".join(str(x)[:200] for x in lines))
    ctx = [" ".join(str(c).split())[:MAX_CHARS] for c in context[-2:] if str(c).strip()]
    if ctx:
        parts.append("Context (earlier, do not translate):\n" + "\n".join(ctx))
    parts.append("TRANSLATE:\n" + " ".join(text.split())[:MAX_CHARS])
    return "\n\n".join(parts)


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
