import Foundation

/// Soniox real-time WebSocket (transcription + translation).
final class SonioxClient {
    private var task: URLSessionWebSocketTask?
    private var closed = false

    var onMessage: ((SonioxMessage) -> Void)?
    var onClose: ((Error?) -> Void)?

    func connect(apiKey: String, config: [String: Any]) {
        var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: request)
        task = t
        closed = false
        t.resume()
        let json = (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        t.send(.string(json)) { [weak self] err in
            if let err { self?.finish(err) }
        }
        receive()
    }

    func sendAudio(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    /// Ask Soniox to finish: it returns the remaining tokens, then closes.
    func end() {
        task?.send(.string("")) { _ in }
    }

    func cancel() {
        task?.cancel(with: .normalClosure, reason: nil)
        finish(nil)
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let msg = try? JSONDecoder().decode(SonioxMessage.self, from: data) {
                    self.onMessage?(msg)
                }
                self.receive()
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        task = nil
        onClose?(error)
    }
}
