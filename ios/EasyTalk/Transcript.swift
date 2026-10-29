import Foundation

/// One token from the Soniox real-time API.
struct Token: Decodable, Equatable {
    var text: String
    var isFinal: Bool
    var speaker: String?
    var translationStatus: String?
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case text, speaker, confidence
        case isFinal = "is_final"
        case translationStatus = "translation_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        translationStatus = try c.decodeIfPresent(String.self, forKey: .translationStatus)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

struct SonioxMessage: Decodable {
    var tokens: [Token]?
    var finished: Bool?
    var errorCode: Int?
    var errorType: String?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

struct Part: Equatable {
    var text: String
    var isFinal: Bool
}

struct Utterance: Identifiable, Equatable {
    let id: Int
    var speaker: String
    var en: [Part] = []
    var zh: [Part] = []
    var ended = false

    var enText: String { Utterance.join(en) }
    var zhText: String { Utterance.tidyChinese(Utterance.join(zh)) }
    var hasPending: Bool { en.contains { !$0.isFinal } || zh.contains { !$0.isFinal } }

    static func join(_ parts: [Part]) -> String {
        parts.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Soniox puts spaces between Chinese clauses ("出来， 而且"); remove them.
    static func tidyChinese(_ s: String) -> String {
        s.replacingOccurrences(
            of: "([\\u3000-\\u303f\\uff00-\\uffef\\u4e00-\\u9fff])\\s+(?=[\\u3000-\\u303f\\uff00-\\uffef\\u4e00-\\u9fff“‘（《])",
            with: "$1", options: .regularExpression)
    }
}

/// Group tokens into utterances: consecutive original tokens of one speaker,
/// split at <end>. Translation tokens go to the oldest utterance whose
/// originals have not been translated yet. (Same logic as the web version.)
func buildUtterances(_ tokens: [Token]) -> [Utterance] {
    var utts: [Utterance] = []
    var cur: Int?
    var pending: [Int] = []
    var transTarget: Int?
    var inTrans = false

    for tok in tokens {
        if tok.translationStatus == "translation" {
            if !inTrans {
                inTrans = true
                transTarget = pending.first ?? cur ?? (utts.isEmpty ? nil : utts.count - 1)
                if transTarget == nil {
                    utts.append(Utterance(id: utts.count, speaker: tok.speaker ?? "?"))
                    transTarget = utts.count - 1
                }
            }
            utts[transTarget!].zh.append(Part(text: tok.text, isFinal: tok.isFinal))
            continue
        }
        if inTrans {
            inTrans = false
            if let t = transTarget, let i = pending.firstIndex(of: t) { pending.remove(at: i) }
        }
        if tok.text == "<end>" {
            if let c = cur { utts[c].ended = true }
            cur = nil
            continue
        }
        if tok.text == "<fin>" { continue }
        let speaker = tok.speaker ?? cur.map { utts[$0].speaker } ?? "?"
        if cur == nil || utts[cur!].speaker != speaker {
            utts.append(Utterance(id: utts.count, speaker: speaker))
            cur = utts.count - 1
        }
        utts[cur!].en.append(Part(text: tok.text, isFinal: tok.isFinal))
        if tok.translationStatus == "original", !pending.contains(cur!) { pending.append(cur!) }
    }
    return utts
}

/// Word list: one per line; "English = 中文" also fixes the translation.
func parseTerms(_ text: String) -> (terms: [String], translations: [[String: String]]) {
    var terms: [String] = []
    var translations: [[String: String]] = []
    var seen = Set<String>()
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        var source = line
        var target: String?
        if let r = line.range(of: "\\s*[=＝]\\s*", options: .regularExpression) {
            source = String(line[..<r.lowerBound])
            target = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        source = String(source.prefix(80))
        if source.isEmpty || seen.contains(source.lowercased()) { continue }
        seen.insert(source.lowercased())
        terms.append(source)
        if let target, !target.isEmpty { translations.append(["source": source, "target": String(target.prefix(80))]) }
        if terms.count >= 150 { break }
    }
    return (terms, translations)
}
