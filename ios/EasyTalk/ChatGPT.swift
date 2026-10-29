import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

/// "Sign in with ChatGPT" for EasyTalk on iPhone (personal use).
/// Ported from the Mac version (server/chatgpt_plan.py). This app has its own
/// registration (client_id, host id) and keeps its tokens only in this
/// iPhone's Keychain. Requests go only to auth.openai.com and api.openai.com.
enum ChatGPT {
    static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let apiBase = URL(string: "https://api.openai.com/v1")!
    static let resource = "https://api.openai.com/v1"
    static let registrationClientID = "dynamic_agent_client"
    static let agentNameHint = "EasyTalk iPhone"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    static let callbackPorts: [UInt16] = [1455, 1456, 1457]
    static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]
}

enum ChatGPTError: LocalizedError {
    case signInRequired
    case message(String)
    case http(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "需要重新登录 ChatGPT"
        case .message(let m): return m
        case .http(let s, let c, let m): return "HTTP \(s) \(c ?? "") \(m)".trimmingCharacters(in: .whitespaces)
        }
    }

    static func from(status: Int, body: Data) -> ChatGPTError {
        if status == 401 { return .signInRequired }
        var code: String?
        var message = String(decoding: body.prefix(400), as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let err = json["error"] as? [String: Any] {
                code = (err["code"] as? String) ?? (err["type"] as? String)
                message = (err["message"] as? String) ?? message
            } else if let err = json["error"] as? String {
                code = err
                message = (json["error_description"] as? String) ?? message
            }
        }
        return .http(status: status, code: code, message: message)
    }
}

/// Short Chinese message for the suggestion panel.
func friendlyChatGPTError(_ error: Error) -> String {
    switch error {
    case ChatGPTError.signInRequired:
        return "ChatGPT 登录已失效，请在设置里重新连接"
    case ChatGPTError.http(let status, let code, _) where status == 429 || (code ?? "").hasPrefix("subscription_sharing"):
        return "ChatGPT 套餐额度暂时用完了"
    case is URLError:
        return "网络连接失败，请稍后再试"
    default:
        return "建议回答失败：\(error.localizedDescription)"
    }
}

// MARK: - stored credentials

struct ChatGPTRecord: Codable {
    var clientID: String
    var hostID: String
    var email: String?
    var subject: String?
    var issuer: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var scopes: [String] = []

    var hasTokens: Bool { !(accessToken ?? "").isEmpty && !(refreshToken ?? "").isEmpty }
    var planGranted: Bool { scopes.contains(ChatGPT.planScope) }

    func clearingTokens() -> ChatGPTRecord {
        var r = self
        r.accessToken = nil
        r.refreshToken = nil
        r.expiresAt = nil
        return r
    }
}

enum ChatGPTStore {
    static let account = "chatgpt-account"

    static func load() -> ChatGPTRecord? {
        guard let json = Keychain.get(account), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatGPTRecord.self, from: data)
    }

    static func save(_ record: ChatGPTRecord) {
        if let data = try? JSONEncoder().encode(record) {
            Keychain.set(account, String(decoding: data, as: UTF8.self))
        }
    }

    /// Signs out but keeps the registration so the next sign-in reuses it.
    static func signOut() {
        if let r = load() { save(r.clearingTokens()) }
    }

    static var connected: Bool { load().map { $0.hasTokens && $0.planGranted } ?? false }
}

// MARK: - HTTP helpers

enum HTTP {
    private static let formAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? v)"
        }.joined(separator: "&")
    }

    static func postForm(_ url: URL, _ fields: [(String, String)]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(encode(fields).utf8)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func getJSON(_ url: URL, token: String? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum B64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    static func randomToken(_ n: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return encode(Data(bytes))
    }
}

// MARK: - tokens, models, streaming

actor ChatGPTClient {
    static let shared = ChatGPTClient()
    private var refreshing: Task<String, Error>?

    /// A usable access token; refreshes when near expiry or when `rejected` was refused.
    func accessToken(rejected: String? = nil) async throws -> String {
        if let running = refreshing { return try await running.value }
        guard let rec = ChatGPTStore.load(), rec.hasTokens else { throw ChatGPTError.signInRequired }
        let fresh = (rec.expiresAt ?? 0) - Date().timeIntervalSince1970 > 120
        if fresh, rec.accessToken != rejected { return rec.accessToken! }
        let task = Task { try await Self.refresh(rec) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private static func refresh(_ rec: ChatGPTRecord) async throws -> String {
        let (status, json) = try await HTTP.postForm(ChatGPT.tokenURL, [
            ("grant_type", "refresh_token"),
            ("client_id", rec.clientID),
            ("refresh_token", rec.refreshToken ?? ""),
            ("resource", ChatGPT.resource),
        ])
        guard (200..<300).contains(status) else {
            if let code = json["error"] as? String, ChatGPT.terminalRefreshErrors.contains(code) {
                ChatGPTStore.save(rec.clearingTokens())
                throw ChatGPTError.signInRequired
            }
            throw ChatGPTError.message("ChatGPT 令牌刷新失败（HTTP \(status)）")
        }
        var r = rec
        r.accessToken = json["access_token"] as? String
        if let t = json["refresh_token"] as? String { r.refreshToken = t }
        if let s = json["scope"] as? String { r.scopes = s.split(separator: " ").map(String.init) }
        r.expiresAt = Date().timeIntervalSince1970 + ((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        ChatGPTStore.save(r)
        guard let token = r.accessToken, !token.isEmpty else { throw ChatGPTError.signInRequired }
        return token
    }

    /// Model slugs available on the plan.
    static func listModels() async throws -> [String] {
        var token = try await shared.accessToken()
        var (status, data) = try await HTTP.getJSON(ChatGPT.apiBase.appendingPathComponent("models"), token: token)
        if status == 401 {
            token = try await shared.accessToken(rejected: token)
            (status, data) = try await HTTP.getJSON(ChatGPT.apiBase.appendingPathComponent("models"), token: token)
        }
        guard status == 200 else { throw ChatGPTError.from(status: status, body: data) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let entries = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        var out: [String] = []
        for e in entries {
            guard let slug = (e["slug"] as? String) ?? (e["id"] as? String), !out.contains(slug) else { continue }
            if let v = e["visibility"] as? String, v != "list" { continue }
            out.append(slug)
        }
        return out
    }

    /// Streams the text of one Responses API call.
    static func streamText(model: String, instructions: String, userText: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(model: model, instructions: instructions, userText: userText) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(model: String, instructions: String, userText: String,
                            onDelta: (String) -> Void) async throws {
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": userText]],
            "store": false,
            "stream": true,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var token = try await shared.accessToken()

        for attempt in 1...2 {
            var req = URLRequest(url: ChatGPT.apiBase.appendingPathComponent("responses"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.httpBody = bodyData
            req.timeoutInterval = 60
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 1 {
                token = try await shared.accessToken(rejected: token)
                continue
            }
            guard status == 200 else {
                var raw = Data()
                for try await b in bytes {
                    raw.append(b)
                    if raw.count > 2000 { break }
                }
                throw ChatGPTError.from(status: status, body: raw)
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { return }
                guard let d = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "response.output_text.delta":
                    if let delta = event["delta"] as? String, !delta.isEmpty { onDelta(delta) }
                case "response.completed":
                    return
                case "response.failed", "error":
                    let err = ((event["response"] as? [String: Any])?["error"] as? [String: Any])
                        ?? (event["error"] as? [String: Any]) ?? [:]
                    throw ChatGPTError.http(status: 200, code: err["code"] as? String,
                                            message: (err["message"] as? String) ?? "response failed")
                case "response.incomplete":
                    throw ChatGPTError.message("回答被截断了")
                default:
                    break
                }
            }
            return
        }
    }
}

// MARK: - sign-in

/// Resolves exactly once, from whichever side finishes first.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Tiny HTTP listener on 127.0.0.1 that receives the OAuth redirect while the
/// ChatGPT login sheet is open (the app stays in the foreground meanwhile).
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "easytalk.loopback")
    private var listener: NWListener?
    var onCallback: (([String: String]) -> Void)?

    func start(ports: [UInt16]) async throws -> UInt16 {
        for p in ports {
            if let l = try? await open(p) {
                listener = l
                return p
            }
        }
        throw ChatGPTError.message("本机端口 1455–1457 都被占用了，请稍后再试")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func open(_ port: UInt16) async throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: l) }
                case .failed(let e), .waiting(let e):
                    if once.claim() { l.cancel(); cont.resume(throwing: e) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var params: [String: String] = [:]
            var matched = false
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
               comps.path == ChatGPT.callbackPath {
                matched = true
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            let ok = matched && params["code"] != nil && params["error"] == nil
            let text = matched
                ? (ok ? "EasyTalk 已连接 ChatGPT，可以关闭此页面。" : "ChatGPT 登录没有完成，请回到 EasyTalk 查看提示。")
                : "Not found"
            let body = Data("""
            <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">\
            <title>EasyTalk</title><p style="font-family:-apple-system;padding:48px 24px;text-align:center;font-size:20px">\(text)</p>
            """.utf8)
            let head = "HTTP/1.1 \(matched ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            if matched { self?.onCallback?(params) }
        }
    }
}

@MainActor
final class ChatGPTAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    func signIn() async throws -> ChatGPTRecord {
        let existing = ChatGPTStore.load()
        let hostID: String = {
            if let h = existing?.hostID, h.hasPrefix("urn:uuid:"), UUID(uuidString: String(h.dropFirst(9))) != nil { return h }
            return "urn:uuid:" + UUID().uuidString.lowercased()
        }()

        let (dStatus, dData) = try await HTTP.getJSON(ChatGPT.discoveryURL)
        guard dStatus == 200,
              let discovery = try? JSONSerialization.jsonObject(with: dData) as? [String: Any],
              let issuer = discovery["issuer"] as? String else {
            throw ChatGPTError.message("连不上 ChatGPT 登录服务（HTTP \(dStatus)）")
        }

        let server = LoopbackServer()
        let port = try await server.start(ports: ChatGPT.callbackPorts)
        defer { server.stop() }

        let redirectURI = "http://127.0.0.1:\(port)\(ChatGPT.callbackPath)"
        let state = B64URL.randomToken()
        let nonce = B64URL.randomToken()
        let verifier = B64URL.randomToken()
        let challenge = B64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let pendingClient = existing?.clientID ?? ChatGPT.registrationClientID

        var query: [(String, String)] = [("client_id", pendingClient)]
        if existing == nil { query.append(("agent_name_hint", ChatGPT.agentNameHint)) }
        query.append(("ext_agent_host_id", hostID))
        if let email = existing?.email { query.append(("login_hint", email)) }
        query += [
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", ChatGPT.scope),
            ("resource", ChatGPT.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
        ]
        guard let url = URL(string: ChatGPT.authorizeURL + "?" + HTTP.encode(query)) else {
            throw ChatGPTError.message("登录地址无效")
        }

        let once = OnceFlag()
        let cb: [String: String] = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
                // Only reached when the sheet is closed before the redirect arrives.
                if once.claim() { cont.resume(throwing: ChatGPTError.message("登录已取消")) }
            }
            server.onCallback = { [weak session] params in
                if once.claim() {
                    cont.resume(returning: params)
                    DispatchQueue.main.async { session?.cancel() }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start(), once.claim() {
                cont.resume(throwing: ChatGPTError.message("无法打开 ChatGPT 登录页"))
            }
        }
        webSession = nil

        guard cb["state"] == state else { throw ChatGPTError.message("登录校验失败（state）") }
        if let err = cb["error"] {
            throw ChatGPTError.message("授权失败：\(err) \(cb["error_description"] ?? "")")
        }
        guard let code = cb["code"], !code.isEmpty else { throw ChatGPTError.message("没有收到授权码") }

        let clientID: String
        if let existing {
            if let returned = cb["client_id"], !returned.isEmpty, returned != existing.clientID {
                throw ChatGPTError.message("client_id 不一致")
            }
            clientID = existing.clientID
        } else {
            guard let issued = cb["client_id"], !issued.isEmpty, issued != ChatGPT.registrationClientID else {
                throw ChatGPTError.message("ChatGPT 没有返回应用注册信息（client_id）")
            }
            clientID = issued
            ChatGPTStore.save(ChatGPTRecord(clientID: issued, hostID: hostID))
        }

        let (status, token) = try await HTTP.postForm(ChatGPT.tokenURL, [
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", ChatGPT.resource),
        ])
        guard (200..<300).contains(status) else {
            throw ChatGPTError.message("换取令牌失败（HTTP \(status) \(token["error"] as? String ?? "")）")
        }
        guard let idToken = token["id_token"] as? String else { throw ChatGPTError.message("没有收到 id_token") }
        let claims = try Self.checkIDToken(idToken, issuer: issuer, clientID: clientID, nonce: nonce)
        let subject = claims["sub"] as? String
        if let prev = existing?.subject, prev != subject {
            throw ChatGPTError.message("登录的是另一个 ChatGPT 账号")
        }

        var record = ChatGPTRecord(clientID: clientID, hostID: hostID)
        record.email = (claims["email"] as? String) ?? existing?.email
        record.subject = subject
        record.issuer = issuer
        record.accessToken = token["access_token"] as? String
        record.refreshToken = token["refresh_token"] as? String
        record.expiresAt = Date().timeIntervalSince1970 + ((token["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        record.scopes = ((token["scope"] as? String) ?? cb["scope"] ?? "").split(separator: " ").map(String.init)

        guard record.refreshToken?.isEmpty == false else {
            ChatGPTStore.save(record.clearingTokens())
            throw ChatGPTError.message("没有收到 refresh token")
        }
        guard record.planGranted else {
            ChatGPTStore.save(record.clearingTokens())
            throw ChatGPTError.message("没有授权使用 ChatGPT 套餐额度（登录时请允许 Use your ChatGPT plan）")
        }
        ChatGPTStore.save(record)
        return record
    }

    /// Claim checks for an id_token received directly from the token endpoint over TLS.
    private static func checkIDToken(_ token: String, issuer: String, clientID: String, nonce: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = B64URL.decode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTError.message("id_token 格式不对")
        }
        guard claims["iss"] as? String == issuer else { throw ChatGPTError.message("id_token issuer 不一致") }
        let aud = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard aud.contains(clientID) else { throw ChatGPTError.message("id_token audience 不一致") }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTError.message("id_token nonce 不一致") }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp + 5 >= Date().timeIntervalSince1970 else {
            throw ChatGPTError.message("id_token 已过期")
        }
        guard (claims["sub"] as? String)?.isEmpty == false else { throw ChatGPTError.message("id_token 没有账号标识") }
        return claims
    }
}
