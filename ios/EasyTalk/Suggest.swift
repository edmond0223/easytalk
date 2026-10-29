import Foundation

/// Reply suggestions: prompt and output parsing (same as server/suggest.py).
struct Suggestion: Identifiable, Equatable {
    let id: Int
    let say: String       // in their language
    let meaning: String   // in my language
}

struct Turn {
    let isMe: Bool
    let text: String
}

enum SuggestStatus: Equatable {
    case idle, notConnected, thinking
    case done(seconds: Double)
    case failed(String)
}

extension TalkScene {
    var promptSetting: String {
        switch self {
        case .work: return "At work in a Canadian supermarket: talking with a supervisor, coworkers or customers."
        case .hospital: return "At a clinic, hospital or pharmacy: talking with a doctor, nurse, receptionist or pharmacist."
        case .school: return "At the child's school: talking with a teacher or school staff."
        case .shop: return "Shopping or at a service counter: prices, questions, returns and exchanges."
        case .phone: return "A phone call with a company, office or service provider."
        case .daily: return "Everyday small talk with neighbours, friends or people nearby."
        }
    }
}

func suggestInstructions(mine: Lang, theirs: Lang) -> String {
    """
    You are EasyTalk, a live conversation helper for a newcomer in Canada. The user (ME) speaks \(mine.promptName) natively and is in a real, spoken conversation in \(theirs.promptName) right now. They will read your suggestions on their phone and say one out loud.

    Write exactly 3 replies ME could say next, in \(theirs.promptName).

    Rules:
    - Natural spoken \(theirs.promptName), simple everyday words, at most 14 words each. Short beats perfect.
    - The 3 replies serve different purposes:
      1. The most likely direct answer, acceptance or acknowledgement.
      2. A polite alternative: decline, delay, set a condition, or offer another option.
      3. A short clarifying question about a specific detail THEM said (not a generic "please repeat").
    - Do not invent facts about the user (names, times, amounts). Keep such details vague instead.
    - If the last THEM turn is unclear or incomplete, make reply 1 a polite request to repeat or slow down.
    - ME may have spoken in either language; THEM lines may be in either language too.

    Output format, exactly 3 lines and nothing else:
    reply in \(theirs.promptName) ||| meaning in \(mine.promptName)
    """
}

func buildSuggestionPrompt(scene: TalkScene, turns: [Turn]) -> String {
    let lines = turns.suffix(12).compactMap { t -> String? in
        let text = String(t.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(600))
        return text.isEmpty ? nil : "\(t.isMe ? "ME" : "THEM"): \(text)"
    }
    let transcript = lines.isEmpty ? "(nothing yet)" : lines.joined(separator: "\n")
    return """
    Setting: \(scene.promptSetting)

    Transcript, oldest first (THEM = the other person, ME = the user):
    \(transcript)

    Write 3 replies for ME to say next.
    """
}

func parseSuggestionLine(_ raw: String) -> (en: String, zh: String)? {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    guard let r = line.range(of: "|||") else { return nil }
    let quotes = CharacterSet(charactersIn: "\"“”")
    let en = String(line[..<r.lowerBound])
        .replacingOccurrences(of: "^\\s*(?:[-*•]|\\d+[.)、:：]?)\\s*", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
    let zh = String(line[r.upperBound...])
        .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
    return en.isEmpty ? nil : (en, zh)
}

// MARK: - polished translation

func polishInstructions(from source: Lang, to target: Lang) -> String {
    """
    You translate live speech captions from \(source.promptName) into natural, fluent \(target.promptName). The reader is a newcomer living in Canada.

    Rules:
    - Translate only the text under TRANSLATE. Earlier lines are context only; never translate or repeat them.
    - Keep the meaning exact, especially numbers, times, dates, amounts, names and places.
    - Natural spoken language, not word-for-word. Keep names and brands as they are when there is no common translation.
    - The text comes from speech recognition and may contain small errors; translate the most likely intended meaning.
    - Use the glossary translations when those terms appear.
    - Output only the \(target.promptName) translation, nothing else.
    """
}

func buildPolishPrompt(setting: String, glossary: [[String: String]], context: [String], text: String) -> String {
    var parts = ["Setting: \(setting)"]
    if !glossary.isEmpty {
        let lines = glossary.prefix(60).compactMap { g -> String? in
            guard let s = g["source"], let t = g["target"] else { return nil }
            return "\(s) = \(t)"
        }
        parts.append("Glossary:\n" + lines.joined(separator: "\n"))
    }
    if !context.isEmpty {
        parts.append("Context (earlier, do not translate):\n" + context.joined(separator: "\n"))
    }
    parts.append("TRANSLATE:\n\(text)")
    return parts.joined(separator: "\n\n")
}
