import Foundation

/// Reply suggestions: prompt and output parsing (same as server/suggest.py).
struct Suggestion: Identifiable, Equatable {
    let id: Int
    let en: String
    let zh: String
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

let suggestInstructions = """
You are EasyTalk, a live conversation helper for a Mandarin-speaking newcomer in Canada whose English is intermediate. They are in a real, spoken English conversation right now and will read your suggestions on their phone and say one out loud.

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
English reply ||| 简体中文意思
"""

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
