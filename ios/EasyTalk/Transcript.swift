import Foundation

/// One token from the Soniox real-time API.
struct Token: Decodable, Equatable {
    var text: String
    var isFinal: Bool
    var speaker: String?
    var translationStatus: String?
    var confidence: Double?
    var language: String?

    enum CodingKeys: String, CodingKey {
        case text, speaker, confidence, language
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
        language = try c.decodeIfPresent(String.self, forKey: .language)
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

/// One stretch of speech. `en` holds the spoken (original) tokens and `zh` the
/// translation tokens; the names date from the English → Chinese version, the
/// languages now follow the user's settings.
struct Utterance: Identifiable, Equatable {
    let id: Int
    var speaker: String
    var en: [Part] = []
    var zh: [Part] = []
    var ended = false
    var langVotes: [String: Int] = [:]
    var transVotes: [String: Int] = [:]

    var enText: String { Utterance.tidyChinese(Utterance.join(en)) }
    var zhText: String { Utterance.tidyChinese(Utterance.join(zh)) }
    /// Language Soniox detected for the spoken words.
    var lang: Lang? { langVotes.max { $0.value < $1.value }.flatMap { Lang(rawValue: $0.key) } }
    /// Language Soniox translated it into.
    var transLang: Lang? { transVotes.max { $0.value < $1.value }.flatMap { Lang(rawValue: $0.key) } }
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

/// Sentence ends, used to line translations up with their originals.
func countSentences(_ text: String, chinese: Bool = false) -> Int {
    let pattern = "[。？！]+|[.?!…]+(?=\\s|$|[\"')\\]»])"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
    return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
}

/// Group tokens into utterances: consecutive original tokens of one speaker,
/// split at <end>. Translation tokens fill the oldest utterance whose
/// originals are not translated yet; once its Chinese has as many sentences
/// as its English, the rest of the run moves on to the next waiting utterance
/// (Soniox sometimes sends two segments' translations in one run).
/// Same logic as the web version (static/app.js).
func buildUtterances(_ tokens: [Token]) -> [Utterance] {
    var utts: [Utterance] = []
    var cur: Int?
    var pending: [Int] = []
    var transTarget: Int?
    var inTrans = false

    func translated(_ i: Int) -> Bool {
        let u = utts[i]
        guard u.ended, !u.zh.isEmpty else { return false }
        let zh = countSentences(u.zh.map(\.text).joined())
        let en = countSentences(u.en.map(\.text).joined())
        return zh >= max(1, en)
    }

    for tok in tokens {
        if tok.translationStatus == "translation" {
            if !inTrans {
                inTrans = true
                transTarget = pending.first ?? cur ?? (utts.isEmpty ? nil : utts.count - 1)
                if transTarget == nil {
                    utts.append(Utterance(id: utts.count, speaker: tok.speaker ?? "?"))
                    transTarget = utts.count - 1
                }
            } else if let t = transTarget, translated(t),
                      let i = pending.firstIndex(of: t), i + 1 < pending.count,
                      tok.text.contains(where: { !$0.isWhitespace }) {
                let next = pending[i + 1]
                pending.remove(at: i)
                transTarget = next
            }
            utts[transTarget!].zh.append(Part(text: tok.text, isFinal: tok.isFinal))
            if let l = tok.language, !tok.text.trimmingCharacters(in: .whitespaces).isEmpty {
                utts[transTarget!].transVotes[l, default: 0] += 1
            }
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
        if let l = tok.language, !tok.text.trimmingCharacters(in: .whitespaces).isEmpty {
            utts[cur!].langVotes[l, default: 0] += 1
        }
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
