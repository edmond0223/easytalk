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
            "language_hints": ["en"],
            "enable_speaker_diarization": true,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": 1500,
            "translation": ["type": "one_way", "target_language": "zh"],
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
        if sawEnd, mode == .chat { maybeSuggest() }
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

    // MARK: suggestions

    private func conversationTurns() -> [Turn] {
        Array(utterances
            .map { Turn(isMe: me.contains($0.speaker), text: $0.enText) }
            .filter { !$0.text.isEmpty }
            .suffix(12))
    }

    /// After the other person finishes a turn, ask ChatGPT for replies.
    private func maybeSuggest() {
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
        let model = defaults.string(forKey: Prefs.chatgptModel).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-6-luna"
        suggestTask = Task { [weak self] in
            let started = Date()
            var buf = ""
            do {
                for try await delta in ChatGPTClient.streamText(model: model, instructions: suggestInstructions,
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
        suggestions.append(Suggestion(id: suggestions.count, en: item.en, zh: item.zh))
    }

    private func rebuild() {
        utterances = buildUtterances(finals + nonFinals)
        for u in utterances where speakerNumbers[u.speaker] == nil {
            speakerNumbers[u.speaker] = speakerNumbers.count + 1
        }
        revision += 1
    }
}
