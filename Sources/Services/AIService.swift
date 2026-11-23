import Foundation
import Network
import Combine

/// Connection to the Desk Bridge on your PC (Claude Code behind it).
/// Finds the PC automatically with Bonjour, checks it every minute, and streams answers.
final class AIService: ObservableObject {
    enum State: Equatable { case notSetUp, searching, online, offline, wrongCode }

    enum AIError: LocalizedError {
        case notSetUp, unreachable, wrongCode, server(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: return "The AI on your PC isn't set up yet."
            case .unreachable: return "Can't reach your PC on Wi-Fi."
            case .wrongCode: return "The pairing code doesn't match."
            case .server(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .notSetUp
    @Published private(set) var serverName = ""
    @Published private(set) var model = ""
    @Published private(set) var lastSeen: Date? = nil
    @Published private(set) var lastAnswerMs: Int? = nil
    @Published private(set) var foundAutomatically = false
    @Published private(set) var host: String? = nil
    @Published var code: String {
        didSet {
            UserDefaults.standard.set(code, forKey: Self.codeKey)
            check()
        }
    }
    @Published var manualHost: String {
        didSet {
            UserDefaults.standard.set(manualHost, forKey: Self.manualKey)
            if !manualHost.trimmingCharacters(in: .whitespaces).isEmpty {
                host = manualHost.trimmingCharacters(in: .whitespaces)
                foundAutomatically = false
                check()
            }
        }
    }

    /// Send today's event titles and open tasks with each question, so the AI can plan with you.
    @Published var shareDay: Bool {
        didSet { UserDefaults.standard.set(shareDay, forKey: "ai.shareDay") }
    }

    let port = 8765
    weak var app: AppState?

    private static let codeKey = "ai.code"
    private static let manualKey = "ai.manualHost"
    private static let hostKey = "ai.lastHost"
    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private var checking = false

    init() {
        let d = UserDefaults.standard
        code = d.string(forKey: Self.codeKey) ?? ""
        shareDay = d.object(forKey: "ai.shareDay") as? Bool ?? true
        manualHost = d.string(forKey: Self.manualKey) ?? ""
        let saved = d.string(forKey: Self.manualKey).flatMap { $0.isEmpty ? nil : $0 } ?? d.string(forKey: Self.hostKey)
        host = saved
    }

    /// Set up enough to try asking (a PC address and a pairing code).
    var isConfigured: Bool { host != nil && code.count == 6 }

    // MARK: Discovery (Bonjour: _deskbridge._tcp)

    func startDiscovery() {
        browser?.cancel()
        if state == .notSetUp || state == .offline { setState(isConfigured ? .offline : .searching) }
        let newBrowser = NWBrowser(for: .bonjour(type: "_deskbridge._tcp", domain: nil), using: .tcp)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self, let result = results.first else { return }
            if case let .service(name, _, _, _) = result.endpoint {
                DispatchQueue.main.async { self.serverName = name }
            }
            if self.manualHost.trimmingCharacters(in: .whitespaces).isEmpty {
                self.resolve(result.endpoint)
            }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    /// Bonjour gives a service name; connect once to learn its IPv4 address.
    private func resolve(_ endpoint: NWEndpoint) {
        resolver?.cancel()
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self = self, let connection = connection else { return }
            switch newState {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    DispatchQueue.main.async {
                        self.host = address
                        self.foundAutomatically = true
                        UserDefaults.standard.set(address, forKey: Self.hostKey)
                        self.check()
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
        resolver = connection
    }

    // MARK: Health

    func check() {
        guard let url = url("/health"), !checking else {
            if host == nil { setState(.searching) }
            return
        }
        checking = true
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue(code, forHTTPHeaderField: "X-Desk-Code")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                guard error == nil, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.setState(self.isConfigured ? .offline : .searching)
                    return
                }
                self.serverName = json["name"] as? String ?? self.serverName
                self.model = Self.friendlyModel(json["model"] as? String ?? "")
                self.lastSeen = Date()
                if let ms = json["lastMs"] as? Int { self.lastAnswerMs = ms }
                if self.code.count != 6 {
                    self.setState(.notSetUp)
                } else {
                    self.setState((json["paired"] as? Bool ?? false) ? .online : .wrongCode)
                }
            }
        }.resume()
    }

    private func setState(_ newState: State) {
        let wasOnline = state == .online
        state = newState
        // First connection this launch: fetch the PC's memory (the iPhone imports it once).
        if newState == .online, !wasOnline, !UserDefaults.standard.bool(forKey: "memory.importedFromPC") {
            loadMemories()
        }
        switch newState {
        case .online: app?.aiStatus = .online
        case .offline, .wrongCode: app?.aiStatus = isConfigured ? .offline : .notSetUp
        case .notSetUp, .searching: app?.aiStatus = .notSetUp
        }
    }

    static func friendlyModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("haiku") { return "Claude Haiku" }
        if lower.contains("sonnet") { return "Claude Sonnet" }
        if lower.contains("opus") { return "Claude Opus" }
        if lower.contains("fable") { return "Claude Fable" }
        return raw.isEmpty || raw == "default" ? "Claude" : raw
    }

    // MARK: Asking (streamed)

    /// Streams the answer: `onDelta` gets each new piece of text (on the main thread).
    func ask(_ question: String, context: [String: String], history: [ChatMessage],
             onDelta: @escaping (String) -> Void) async throws -> (answer: String, ms: Int) {
        guard isConfigured, let url = url("/ask") else { throw AIError.notSetUp }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue(code, forHTTPHeaderField: "X-Desk-Code")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let turns = history.suffix(6).map { ["fromUser": $0.fromUser, "text": $0.text] as [String: Any] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "question": question, "context": context, "history": turns, "stream": true
        ])

        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            await MainActor.run { self.setState(.offline) }
            throw AIError.unreachable
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 {
                await MainActor.run { self.setState(.wrongCode) }
                throw AIError.wrongCode
            }
            throw AIError.server("The AI on your PC returned an error (\(http.statusCode)).")
        }

        var answer = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let piece = event["delta"] as? String {
                answer += piece
                await MainActor.run { onDelta(piece) }
            } else if let message = event["error"] as? String {
                throw AIError.server(message)
            } else if event["done"] as? Bool == true {
                if let full = event["answer"] as? String, !full.isEmpty { answer = full }
                if let rawModel = event["model"] as? String {
                    await MainActor.run { self.model = Self.friendlyModel(rawModel) }
                }
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        await MainActor.run {
            self.lastAnswerMs = ms
            self.lastSeen = Date()
            self.setState(.online)
        }
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), ms)
    }

    // MARK: Long-term memory (stored on the PC)

    @Published private(set) var memories: [String] = []
    /// Called with the PC's facts when they're loaded (the iPhone takes them over the first time).
    var onMemories: (([String]) -> Void)? = nil

    /// The iPhone owns memory now: send the whole list to the PC as a backup.
    func backupMemories(_ facts: [String]) {
        memoryRequest(method: "POST", body: ["replace": facts])
    }

    func loadMemories() {
        memoryRequest(method: "GET", body: nil)
    }

    func removeMemory(_ fact: String) {
        memoryRequest(method: "POST", body: ["remove": fact])
    }

    func clearMemories() {
        memoryRequest(method: "POST", body: ["clear": true])
    }

    private func memoryRequest(method: String, body: [String: Any]?) {
        guard isConfigured, let url = url("/memory") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue(code, forHTTPHeaderField: "X-Desk-Code")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let facts = json["facts"] as? [String] else { return }
            DispatchQueue.main.async {
                self?.memories = facts
                self?.onMemories?(facts)
            }
        }.resume()
    }

    /// Fresh conversation on the PC (after "Clear conversation").
    func reset() {
        guard isConfigured, let url = url("/reset") else { return }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue(code, forHTTPHeaderField: "X-Desk-Code")
        URLSession.shared.dataTask(with: request).resume()
    }

    private func url(_ path: String) -> URL? {
        guard let host = host, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)\(path)")
    }
}
