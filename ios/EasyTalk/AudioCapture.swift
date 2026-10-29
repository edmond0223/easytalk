import AVFoundation

/// Microphone → 16 kHz mono 16-bit PCM in ~100 ms chunks.
/// With the "audio" background mode this keeps running when the screen locks.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noConverter
        var errorDescription: String? { "无法初始化麦克风音频格式" }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private var pending = Data()
    private var peak: Int16 = 0
    private let chunkBytes = 3200 // 100 ms at 16 kHz, 16-bit

    /// Called on the audio thread with a PCM chunk and its peak level (0...1).
    var onChunk: ((Data, Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw CaptureError.noConverter }
        converter = conv
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        let n = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: ch[0], count: n)
        for v in samples {
            let a = v == Int16.min ? Int16.max : abs(v)
            if a > peak { peak = a }
        }
        pending.append(samples)
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onChunk?(Data(chunk), Float(peak) / 32767)
            peak = 0
        }
    }
}
