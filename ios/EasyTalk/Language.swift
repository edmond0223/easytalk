import Foundation

/// Languages EasyTalk can listen to, translate and speak.
enum Lang: String, CaseIterable, Identifiable {
    case zh, en, fr

    var id: String { rawValue }

    /// Name shown in the (Chinese) interface.
    var title: String {
        switch self {
        case .zh: return "中文"
        case .en: return "英语"
        case .fr: return "法语"
        }
    }

    /// Name used in ChatGPT prompts.
    var promptName: String {
        switch self {
        case .zh: return "Simplified Chinese (Mandarin)"
        case .en: return "Canadian English"
        case .fr: return "Canadian French"
        }
    }

    /// Voice for the iPhone's built-in speech (fallback only).
    var speechCode: String {
        switch self {
        case .zh: return "zh-CN"
        case .en: return "en-CA"
        case .fr: return "fr-CA"
        }
    }
}

enum LangPrefs {
    static let mineKey = "myLang", theirsKey = "theirLang"

    static var mine: Lang { Lang(rawValue: UserDefaults.standard.string(forKey: mineKey) ?? "") ?? .zh }

    static var theirs: Lang {
        let t = Lang(rawValue: UserDefaults.standard.string(forKey: theirsKey) ?? "") ?? .en
        if t != mine { return t }
        return mine == .en ? .zh : .en
    }
}

/// Quick phrases: label in my language, spoken in theirs.
struct Phrase: Identifiable {
    let id: Int
    let texts: [Lang: (label: String, say: String)]

    func label(_ l: Lang) -> String { texts[l]?.label ?? "" }
    func say(_ l: Lang) -> String { texts[l]?.say ?? "" }

    static let all: [Phrase] = [
        Phrase(id: 1, texts: [
            .zh: ("请再说一遍", "不好意思，能再说一遍吗？"),
            .en: ("Say again", "Sorry, could you say that again?"),
            .fr: ("Répéter", "Pardon, pouvez-vous répéter, s'il vous plaît ?"),
        ]),
        Phrase(id: 2, texts: [
            .zh: ("请说慢一点", "能说慢一点吗？"),
            .en: ("Slower", "Could you speak a little slower, please?"),
            .fr: ("Plus lentement", "Pourriez-vous parler un peu plus lentement, s'il vous plaît ?"),
        ]),
        Phrase(id: 3, texts: [
            .zh: ("让我想一下", "让我想一下。"),
            .en: ("Let me think", "Let me think for a second."),
            .fr: ("Je réfléchis", "Laissez-moi réfléchir une seconde."),
        ]),
        Phrase(id: 4, texts: [
            .zh: ("说简单一点", "不好意思，我的中文不太好，能说简单一点吗？"),
            .en: ("Simpler", "Sorry, my English isn't great. Could you say it more simply?"),
            .fr: ("Plus simple", "Désolé, mon français n'est pas très bon. Pourriez-vous le dire plus simplement ?"),
        ]),
        Phrase(id: 5, texts: [
            .zh: ("能写下来吗", "能帮我写下来吗？"),
            .en: ("Write it down", "Could you write that down for me, please?"),
            .fr: ("Par écrit", "Pourriez-vous me l'écrire, s'il vous plaît ?"),
        ]),
        Phrase(id: 6, texts: [
            .zh: ("我明白了", "好的，我明白了，谢谢。"),
            .en: ("I understand", "Okay, I understand. Thank you."),
            .fr: ("Je comprends", "D'accord, je comprends. Merci."),
        ]),
    ]
}
