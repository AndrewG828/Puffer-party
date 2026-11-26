import Foundation

/// Live connection to one room on party.krillion.io: snapshots, patches,
/// acknowledged actions, presence pings and reconnects. Port of the web
/// client's websocket room stream.
@MainActor
final class RoomConnection {
    enum Status: Equatable {
        case connecting, live, reconnecting, refused, removed, gone, paused
    }

    let code: String
    let playerKey: String
    var onRoom: ((JSONValue) -> Void)?
    var onStatus: ((Status) -> Void)?
    private(set) var removalMessage: String?

    private var room: JSONValue?
    private var task: URLSessionWebSocketTask?
    private var opened = false
    private var closed = false
    private var removed = false
    private var backoff = ReconnectBackoff(quickFirst: true)
    private var retryTask: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var probe: Task<Void, Never>?
    private var heardAt = Date.distantPast
    private var pending: [String: CheckedContinuation<ActResult, Never>] = [:]
    private var pendingTimeouts: [String: Task<Void, Never>] = [:]
    private var counter = 0

    init(code: String, playerKey: String) {
        self.code = code
        self.playerKey = playerKey
    }

    func start() {
        open()
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Party.presencePingMs) * 1_000_000)
                self?.ping()
            }
        }
    }

    func close() {
        closed = true
        retryTask?.cancel()
        pingLoop?.cancel()
        probe?.cancel()
        failPending()
        task?.cancel(with: .normalClosure, reason: Data("leaving".utf8))
        task = nil
    }

    /// Checks the socket is still alive (e.g. when the app comes back to the foreground).
    func ping() {
        guard send(["t": "ping"]), probe == nil else { return }
        let socket = task
        let sentAt = Date()
        probe = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.probe = nil
            if let socket, self.task === socket, self.heardAt < sentAt { self.drop(socket) }
        }
    }

    /// Sends an action and waits for the server's ack. Status -1 means the
    /// socket wasn't open and the caller should fall back to HTTP.
    func act(_ action: [String: Any]) async -> ActResult {
        counter += 1
        let cid = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))-\(counter)"
        guard send(["t": "act", "cid": cid, "action": action]) else {
            return ActResult(ok: false, error: "no signal", status: -1)
        }
        if Date().timeIntervalSince(heardAt) > 2 { ping() }
        return await withCheckedContinuation { continuation in
            pending[cid] = continuation
            pendingTimeouts[cid] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.resolve(cid, ActResult(ok: false, error: "no signal", status: 0))
            }
        }
    }

    // MARK: Socket lifecycle

    private func open() {
        guard !closed else { return }
        Task { [weak self] in
            do {
                let token = try await PartyAPI.shared.guestToken()
                self?.connect(token: token)
            } catch is PartyVerificationError {
                self?.onStatus?(.refused)
            } catch {
                guard let self, !self.closed else { return }
                self.onStatus?(.reconnecting)
                self.scheduleRetry()
            }
        }
    }

    private func connect(token: String) {
        guard !closed, task == nil else { return }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Party.server.host
        components.path = "/rooms/\(code)/ws"
        components.queryItems = [
            URLQueryItem(name: "key", value: playerKey),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else { return }
        let socket = PartyAPI.shared.urlSession.webSocketTask(with: url)
        task = socket
        opened = false
        socket.resume()
        listen(socket)
    }

    private func listen(_ socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.socketClosed(socket)
                    return
                }
                guard let self else { return }
                guard self.task === socket else { return }
                self.heardAt = Date()
                self.opened = true
                var text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, let json = JSONValue.parse(text) { self.receive(json) }
            }
        }
    }

    private func socketClosed(_ socket: URLSessionWebSocketTask) {
        guard task === socket else { return }
        task = nil
        opened = false
        failPending()
        if closed { return }
        if removed {
            onStatus?(.removed)
            return
        }
        let closeCode = socket.closeCode.rawValue
        if closeCode == 4403 {
            onStatus?(.refused)
            return
        }
        if closeCode == 4404 || closeCode == 4410 { return }
        if closeCode == 4401 { PartyAPI.shared.clearToken() }
        onStatus?(.reconnecting)
        scheduleRetry()
    }

    private func drop(_ socket: URLSessionWebSocketTask) {
        guard task === socket, !closed else { return }
        task = nil
        opened = false
        socket.cancel(with: .goingAway, reason: Data("silent".utf8))
        failPending()
        onStatus?(.reconnecting)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = backoff.disconnected()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    // MARK: Messages

    private func receive(_ message: JSONValue) {
        switch message["t"]?.string {
        case "snap":
            guard let snapshot = message["room"] else { return }
            room = snapshot
            backoff.receivedRoom()
            onStatus?(.live)
            onRoom?(snapshot)
        case "patch":
            guard let current = room, let patch = message["patch"],
                  let next = RoomPatch.apply(current, patch) else {
                _ = send(["t": "sync"])
                return
            }
            room = next
            onRoom?(next)
        case "ack":
            guard let cid = message["cid"]?.string else { return }
            let ok = message["ok"]?.bool ?? false
            resolve(cid, ActResult(
                ok: ok,
                error: message["error"]?.string,
                submit: PartyAPI.submitResult(message["submit"]),
                status: message["status"]?.int ?? (ok ? 200 : 400),
                room: nil
            ))
        case "gone":
            closed = true
            onStatus?(message["paused"]?.bool == true ? .paused : .gone)
        case "removed":
            removed = true
            if let text = message["message"]?.string, !text.isEmpty { removalMessage = text }
            onStatus?(.removed)
        default:
            break
        }
    }

    @discardableResult
    private func send(_ object: [String: Any]) -> Bool {
        guard let task, opened, task.state == .running else { return false }
        let data = JSONBody.data(object)
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        return true
    }

    private func resolve(_ cid: String, _ result: ActResult) {
        pendingTimeouts.removeValue(forKey: cid)?.cancel()
        pending.removeValue(forKey: cid)?.resume(returning: result)
    }

    private func failPending() {
        for cid in Array(pending.keys) {
            resolve(cid, ActResult(ok: false, error: "no signal", status: 0))
        }
    }
}
