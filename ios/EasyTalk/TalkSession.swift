import AVFoundation
import Foundation
import Observation
import UIKit

enum Mode: String, CaseIterable, Identifiable {
    case chat, lecture
    var id: String { rawValue }
    var title: String { self == .chat ? "对话" : "会议演讲" }
}

/// Conversation setting (named TalkScene so it does not clash with SwiftUI.Scene).
enum TalkScene: String, CaseIterable, Identifiable {
    case work, hospital, school, shop, phone, daily
    var id: String { rawValue }
    var title: String {
        switch self {
        case .work: return "工作"
        case .hospital: return "医院"
        case .school: return "学校"
        case .shop: return "购物"
        case .phone: return "电话"
        case .daily: return "日常"
        }
    }
    var domain: String {
        switch self {
        case .work: return "Supermarket job in Canada: supervisor, coworkers, customers, aisles, shifts, breaks"
        case .hospital: return "Clinic, hospital or pharmacy in Canada: symptoms, appointments, medication, OHIP"
        case .school: return "Parent talking with the child's school teacher or staff in Canada"
        case .shop: return "Shopping in Canada: prices, sizes, receipts, returns, exchanges"
        case .phone: return "Phone call with a company or office in Canada"
        case .daily: return "Everyday small talk in Canada"
        }
    }
}

enum Prefs {
    static let scene = "scene", topic = "topic", terms = "terms", mode = "mode", fontSize = "fontSize"
    static let chatgptModel = "chatgptModel", chatgptModels = "chatgptModels"
    static let suggestEnabled = "suggestEnabled"
    static let polishEnabled = "polishEnabled"
    static let autoSpeak = "autoSpeak"

    /// When I speak my own language, read the translation aloud for the other person.
    static var autoSpeakOn: Bool { UserDefaults.standard.object(forKey: autoSpeak) as? Bool ?? true }

    /// ChatGPT re-translates each finished sentence unless switched off.
    static var polishOn: Bool { UserDefaults.standard.object(forKey: polishEnabled) as? Bool ?? true }

    /// Reply suggestions are on unless the user switched them off.
    static var suggestionsOn: Bool { UserDefaults.standard.object(forKey: suggestEnabled) as? Bool ?? true }
}

/// One listening session: microphone → Soniox → transcript.
@MainActor
@Observable
final class TalkSession {
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: Prefs.mode) ?? "") ?? .chat {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Prefs.mode) }
    }
    private(set) var running = false
    private(set) var status = "未开始"
    private(set) var level: Float = 0
    private(set) var utterances: [Utterance] = []
    private(set) var revision = 0
    private(set) var speakerNumbers: [String: Int] = [:]
    var me: Set<String> = []
    var errorMessage: String?
    private(set) var suggestions: [Suggestion] = []
    private(set) var suggestStatus: SuggestStatus = .idle
    private var suggestTask: Task<Void, Never>?
    private var lastSuggestKey = ""
    /// Fluent ChatGPT translations of finished sentences, keyed by their English text.
    private(set) var polished: [String: String] = [:]
    @ObservationIgnored private var polishedLang: [String: Lang] = [:]
    @ObservationIgnored private var polishing: Set<String> = []
    @ObservationIgnored private var spokenKeys: Set<String> = []
    /// Language pair, fixed for the length of a listening session.
    private(set) var mine: Lang = LangPrefs.mine
    private(set) var theirs: Lang = LangPrefs.theirs

    private var finals: [Token] = []
    private var nonFinals: [Token] = []
    private var sessionNo = 0
    private var audio: AudioCapture?
    private var client: SonioxClient?
    private var stopping = false
    private var interruptionObserver: NSObjectProtocol?

    // MARK: speakers

    func speakerName(_ key: String) -> String {
        if me.contains(key) { return "我" }
        let n = speakerNumbers[key] ?? 1
        if mode == .lecture { return "发言人 \(n)" }
        return speakerNumbers.count <= 1 ? "对方" : "对方 \(n)"
    }

    /// Spoken by me: tagged as me, or spoken in my language.
    func isMine(_ u: Utterance) -> Bool {
        me.contains(u.speaker) || u.lang == mine
    }

    /// Text of this utterance in a given language: the original or the
    /// translation, whichever is in that language. Lines recorded under an
    /// earlier language pair fall back sensibly (original on their side,
    /// translation on mine) instead of showing the same text twice.
    func text(_ u: Utterance, in lang: Lang) -> String {
        let orig = u.lang ?? theirs
        let trans = polishedLang[u.enText] ?? u.transLang ?? (orig == mine ? theirs : mine)
        if orig == lang { return u.enText }
        if trans == lang { return translation(for: u) }
        let other = lang == mine ? theirs : mine
        if orig == other { return translation(for: u) }
        if trans == other { return u.enText }
        return lang == mine ? translation(for: u) : u.enText
    }

    /// Pick up language changes made in Settings (only while not listening).
    func reloadLanguages() {
        guard !running else { return }
        mine = LangPrefs.mine
        theirs = LangPrefs.theirs
    }

    func toggleMe(_ key: String) {
        if me.contains(key) { me.remove(key) } else { me.insert(key) }
    }

    var distinctSpeakers: Int { Set(utterances.map(\.speaker)).count }

    // MARK: start / stop

    func start() async {
        guard !running else { return }
        guard let key = Keychain.get(Keychain.sonioxAccount), !key.isEmpty else {
            errorMessage = "请先点右上角的设置，填写 Soniox API Key"
            return
        }
        guard await AudioCapture.requestPermission() else {
            errorMessage = "没有麦克风权限：请到 iPhone 设置 → EasyTalk，打开麦克风"
            return
        }
        errorMessage = nil
        mine = LangPrefs.mine
        theirs = LangPrefs.theirs
        running = true
        stopping = false
        status = "连接中…"
        sessionNo += 1
        let sn = sessionNo

        let client = SonioxClient()
        self.client = client
        client.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg, session: sn) }
        }
        client.onClose = { [weak self] err in
            Task { @MainActor in self?.closed(err, session: sn) }
        }
        client.connect(apiKey: key, config: makeConfig())

        let audio = AudioCapture()
        audio.onChunk = { [weak self, weak client] data, peak in
            client?.sendAudio(data)
            Task { @MainActor in self?.level = peak }
        }
        do {
            try audio.start()
            self.audio = audio
            status = "正在听"
            Speaker.shared.recording = true
            UIApplication.shared.isIdleTimerDisabled = true
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor in
                    self?.errorMessage = "收音被打断（比如来电），已停止"
                    self?.stop()
                }
            }
        } catch {
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            client.cancel()
            finishStop()
        }
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true
        status = "正在收尾…"
        audio?.stop()
        audio = nil
        client?.end()
        let sn = sessionNo
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if self.sessionNo == sn, self.running { self.client?.cancel() }
        }
    }

    func clear() {
        finals = []
        nonFinals = []
        me = []
        speakerNumbers = [:]
        suggestTask?.cancel()
        suggestions = []
        suggestStatus = .idle
        lastSuggestKey = ""
        polished = [:]
        polishedLang = [:]
        polishing = []
        spokenKeys = []
        rebuild()
    }

    // MARK: Soniox

    private func makeConfig() -> [String: Any] {
        let defaults = UserDefaults.standard
        let scene = TalkScene(rawValue: defaults.string(forKey: Prefs.scene) ?? "") ?? .work
        let topic = (defaults.string(forKey: Prefs.topic) ?? "").trimmingCharacters(in: .whitespaces)
        var general: [[String: String]]
        if mode == .lecture {
            general = [["key": "domain", "value": "Meeting, lecture or presentation"]]
            if !topic.isEmpty { general.append(["key": "topic", "value": topic]) }
        } else {
            general = [["key": "domain", "value": scene.domain]]
        }
        general.append(["key": "location", "value": "Mississauga, Ontario, Canada"])
        var context: [String: Any] = ["general": general]
        let parsed = parseTerms(defaults.string(forKey: Prefs.terms) ?? "")
        if !parsed.terms.isEmpty { context["terms"] = parsed.terms }
        if !parsed.translations.isEmpty { context["translation_terms"] = parsed.translations }

        var config: [String: Any] = [
            "model": "stt-rt-v5",
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "language_hints": [theirs.rawValue, mine.rawValue],
            "enable_language_identification": true,
            "enable_speaker_diarization": true,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": 1500,
            "translation": ["type": "two_way", "language_a": theirs.rawValue, "language_b": mine.rawValue],
            "context": context,
        ]
        if mode == .lecture {
            config["endpoint_latency_adjustment_level"] = 1
            config["endpoint_sensitivity"] = 0.5
        }
        return config
    }

    private func handle(_ msg: SonioxMessage, session: Int) {
        guard session == sessionNo else { return }
        if let code = msg.errorCode {
            let hint = code == 402 ? "（Soniox 余额不足，请到控制台充值）" : ""
            errorMessage = "Soniox 错误 \(code)\(hint)：\(msg.errorMessage ?? msg.errorType ?? "")"
            stopping = true
            client?.cancel()
            finishStop()
            return
        }
        var nf: [Token] = []
        var sawEnd = false
        for var t in msg.tokens ?? [] where !t.text.isEmpty {
            if let s = t.speaker { t.speaker = "\(session):\(s)" }
            if t.isFinal {
                finals.append(t)
                if t.text == "<end>" { sawEnd = true }
            } else {
                nf.append(t)
            }
        }
        nonFinals = nf
        rebuild()
        if sawEnd {
            polishFinished()
            if mode == .chat {
                maybeSuggest()
                maybeAutoSpeak()
            }
        }
        if msg.finished == true { client?.cancel() }
    }

    private func closed(_ error: Error?, session: Int) {
        guard session == sessionNo, running else { return }
        if !stopping {
            errorMessage = "连接断开了" + (error.map { "：\($0.localizedDescription)" } ?? "")
        }
        finishStop()
    }

    private func finishStop() {
        running = false
        stopping = false
        audio?.stop()
        audio = nil
        client = nil
        nonFinals = []
        level = 0
        Speaker.shared.recording = false
        micMuted.value = false
        rebuild()
        status = errorMessage == nil ? "已停止" : "出错"
        UIApplication.shared.isIdleTimerDisabled = false
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
    }

    // MARK: polished translation

    /// The best Chinese we have for this utterance.
    func translation(for u: Utterance) -> String {
        polished[u.enText] ?? u.zhText
    }

    /// Send each newly finished sentence to ChatGPT for a fluent translation.
    private func polishFinished() {
        guard Prefs.polishOn, ChatGPTStore.connected else { return }
        let defaults = UserDefaults.standard
        let setting: String = {
            if mode == .lecture {
                let topic = (defaults.string(forKey: Prefs.topic) ?? "").trimmingCharacters(in: .whitespaces)
                return topic.isEmpty ? "A meeting, lecture or presentation." : "A meeting or lecture about: \(topic)"
            }
            return (TalkScene(rawValue: defaults.string(forKey: Prefs.scene) ?? "") ?? .work).promptSetting
        }()
        let glossary = parseTerms(defaults.string(forKey: Prefs.terms) ?? "").translations
        let model = defaults.string(forKey: Prefs.chatgptModel).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-6-luna"

        let spoken = utterances.filter { !$0.enText.isEmpty }
        for (i, u) in spoken.enumerated().suffix(6) {
            let key = u.enText
            guard u.ended, !u.en.contains(where: { !$0.isFinal }),
                  polished[key] == nil, !polishing.contains(key) else { continue }
            let source = u.lang ?? theirs
            guard source == mine || source == theirs else { continue }
            let target = source == mine ? theirs : mine
            polishing.insert(key)
            let context = spoken[max(0, i - 2)..<i].map(\.enText)
            let prompt = buildPolishPrompt(setting: setting, glossary: glossary, context: context, text: key)
            let instructions = polishInstructions(from: source, to: target)
            Task { [weak self] in
                var out = ""
                do {
                    for try await delta in ChatGPTClient.streamText(model: model, instructions: instructions,
                                                                    userText: prompt) {
                        out += delta
                    }
                    var text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if target == .zh { text = Utterance.tidyChinese(text) }
                    if !text.isEmpty, self?.polishing.contains(key) == true {
                        self?.polishedLang[key] = target
                        self?.polished[key] = text
                    }
                } catch {
                    // Keep Soniox's translation.
                }
                self?.polishing.remove(key)
            }
        }
    }

    // MARK: suggestions

    private func conversationTurns() -> [Turn] {
        Array(utterances
            .map { Turn(isMe: isMine($0), text: $0.enText) }
            .filter { !$0.text.isEmpty }
            .suffix(12))
    }

    /// After the other person finishes a turn, ask ChatGPT for replies.
    private func maybeSuggest() {
        guard Prefs.suggestionsOn else { return }
        let turns = conversationTurns()
        guard let last = turns.last, !last.isMe,
              last.text.split(whereSeparator: \.isWhitespace).count >= 2 else { return }
        let key = "\(turns.count)|\(last.text)"
        guard key != lastSuggestKey else { return }
        lastSuggestKey = key
        guard ChatGPTStore.connected else {
            suggestStatus = .notConnected
            return
        }
        requestSuggestions(turns)
    }

    /// Called when the user switches suggestions off.
    func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        suggestStatus = .idle
    }

    func refreshSuggestions() {
        let turns = conversationTurns()
        guard !turns.isEmpty else { return }
        guard ChatGPTStore.connected else {
            suggestStatus = .notConnected
            return
        }
        requestSuggestions(turns)
    }

    private func requestSuggestions(_ turns: [Turn]) {
        suggestTask?.cancel()
        suggestions = []
        suggestStatus = .thinking
        let defaults = UserDefaults.standard
        let scene = TalkScene(rawValue: defaults.string(forKey: Prefs.scene) ?? "") ?? .work
        let prompt = buildSuggestionPrompt(scene: scene, turns: turns)
        let instructions = suggestInstructions(mine: mine, theirs: theirs)
        let model = defaults.string(forKey: Prefs.chatgptModel).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-6-luna"
        suggestTask = Task { [weak self] in
            let started = Date()
            var buf = ""
            do {
                for try await delta in ChatGPTClient.streamText(model: model, instructions: instructions,
                                                                userText: prompt) {
                    buf += delta
                    while let nl = buf.firstIndex(of: "\n") {
                        let line = String(buf[..<nl])
                        buf.removeSubrange(...nl)
                        self?.addSuggestion(line)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.addSuggestion(buf)
                self?.suggestStatus = .done(seconds: Date().timeIntervalSince(started))
            } catch {
                guard !Task.isCancelled else { return }
                self?.suggestStatus = .failed(friendlyChatGPTError(error))
            }
        }
    }

    private func addSuggestion(_ line: String) {
        guard suggestions.count < 3, let item = parseSuggestionLine(line) else { return }
        suggestions.append(Suggestion(id: suggestions.count, say: item.en, meaning: item.zh))
    }

    // MARK: speak my words in their language

    /// When I finish a sentence in my own language, read its translation aloud.
    private func maybeAutoSpeak() {
        guard Prefs.autoSpeakOn,
              let u = utterances.last(where: { $0.ended && !$0.enText.isEmpty }),
              u.lang == mine, !spokenKeys.contains(u.enText) else { return }
        let key = u.enText
        spokenKeys.insert(key)
        // Wait briefly for the polished translation (or for Soniox's to finish arriving).
        let wait: Double = (Prefs.polishOn && ChatGPTStore.connected) ? 3.0 : 1.0
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if self?.polished[key] != nil { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, self.running,
                  let latest = self.utterances.first(where: { $0.enText == key }) else { return }
            Speaker.shared.speak(self.text(latest, in: self.theirs), lang: self.theirs)
        }
    }

    private func rebuild() {
        utterances = buildUtterances(finals + nonFinals)
        for u in utterances where speakerNumbers[u.speaker] == nil {
            speakerNumbers[u.speaker] = speakerNumbers.count + 1
        }
        revision += 1
    }
}
