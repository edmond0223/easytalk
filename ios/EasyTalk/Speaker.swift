import AVFoundation
import Foundation
import Observation

/// Thread-safe flag read on the audio thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// While EasyTalk speaks, the mic sends silence so the phone's own voice is not
/// transcribed as another speaker.
let micMuted = AtomicFlag()

private final class SpeakerDelegate: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish?() }
}

/// Speaks English with Soniox TTS (natural voice); the iPhone voice is the fallback.
@MainActor
@Observable
final class Speaker {
    static let shared = Speaker()

    private(set) var speakingText: String?
    /// Set by TalkSession while listening (the audio session is then play-and-record).
    var recording = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = SpeakerDelegate()
    @ObservationIgnored private var cache: [String: Data] = [:]
    @ObservationIgnored private var generation = 0

    init() {
        synth.delegate = delegate
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.finished() }
        }
    }

    func speak(_ text: String) {
        stop()
        generation += 1
        let gen = generation
        speakingText = text
        Task { await play(text, generation: gen) }
    }

    func stop() {
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingText = nil
        micMuted.value = false
    }

    private func finished() {
        speakingText = nil
        micMuted.value = false
    }

    private func play(_ text: String, generation gen: Int) async {
        let session = AVAudioSession.sharedInstance()
        if !recording {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        do {
            let data = try await fetch(text)
            guard gen == generation else { return }
            let p = try AVAudioPlayer(data: data)
            p.delegate = delegate
            player = p
            micMuted.value = recording
            if !p.play() { throw URLError(.cannotDecodeContentData) }
        } catch {
            guard gen == generation else { return }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "en-CA") ?? AVSpeechSynthesisVoice(language: "en-US")
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            micMuted.value = recording
            synth.speak(u)
        }
    }

    private func fetch(_ text: String) async throws -> Data {
        if let d = cache[text] { return d }
        guard let key = Keychain.get(Keychain.sonioxAccount), !key.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        var req = URLRequest(url: URL(string: "https://tts-rt.soniox.com/tts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-rt-v2", "language": "en", "voice": "Adrian",
            "audio_format": "mp3", "text": String(text.prefix(300)),
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[text] = data
        return data
    }
}
