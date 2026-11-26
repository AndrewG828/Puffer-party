import Foundation

/// Error from a party request. `status` 0 means the request never got an answer.
struct PartyError: LocalizedError, Equatable {
    static let verificationCode = "verification"

    let message: String
    let status: Int
    var code: String?
    var room: String?

    var errorDescription: String? { message }

    /// Room the player is already seated in, when the server refused because of it.
    var seatedElsewhereRoom: String? {
        code == Party.seatedElsewhere ? room : nil
    }

    /// Text shown under the form that failed (the web's `errorText`).
    func displayText(code roomCode: String? = nil) -> String {
        if status == 404, let roomCode { return "no room \(roomCode)" }
        if status == 0 { return "no signal. try again" }
        return message
    }

    /// Whether a join failure is worth retrying silently.
    var isPassing: Bool {
        if code == Party.seatedElsewhere { return false }
        return status == 0 || status == 401 || status == 429 || status >= 500 || code == PartyError.verificationCode
    }
}

/// The bot check could not be completed (cancelled, expired, unavailable).
struct PartyVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SeatGrant: Equatable {
    let code: String
    let playerId: String
    let playerKey: String
}

enum QuickPlayResult: Equatable {
    /// Nothing better was found: stay at the current table.
    case stay
    case seated(SeatGrant)
}

struct SubmitResult: Equatable {
    let accepted: Bool
    let why: String?
}

struct ActResult {
    var ok: Bool
    var error: String?
    var submit: SubmitResult?
    var status: Int
    var room: JSONValue?
}

/// Talks to the same backend as krillion.io/party.
@MainActor
final class PartyAPI {
    static let shared = PartyAPI()

    /// Presents the Cloudflare Turnstile check and returns its token.
    var verifier: ((_ siteKey: String, _ guestId: String) async throws -> String)?

    private let session: URLSession
    private var token: (value: String, exp: Double)?
    private var tokenLoad: Task<String, Error>?

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config)
    }

    var urlSession: URLSession { session }

    // MARK: Guest token

    func clearToken() {
        token = nil
    }

    /// Short-lived token the party server accepts. When `interactive` is
    /// false a pending bot check fails instead of being shown.
    func guestToken(interactive: Bool = true) async throws -> String {
        if let token, token.exp * 1000 - Date().timeIntervalSince1970 * 1000 > 60_000 {
            return token.value
        }
        guard interactive else { return try await loadToken(interactive: false) }
        if let tokenLoad { return try await tokenLoad.value }
        let load = Task { try await self.loadToken(interactive: true) }
        tokenLoad = load
        defer { tokenLoad = nil }
        return try await load.value
    }

    /// Fetches a token early so the first join is fast.
    func warmIdentity() {
        Task { _ = try? await guestToken(interactive: false) }
    }

    private func loadToken(interactive: Bool) async throws -> String {
        var (status, json) = try await requestToken(captcha: nil)
        if status == 403, json?["code"]?.string == "party-verification" {
            guard interactive else { throw PartyVerificationError(message: "Verification needed.") }
            guard let siteKey = json?["siteKey"]?.string, let guestId = json?["guestId"]?.string,
                  let verifier else {
                throw PartyVerificationError(message: "Verification is unavailable.")
            }
            let captcha = try await verifier(siteKey, guestId)
            (status, json) = try await requestToken(captcha: captcha)
        }
        if status >= 500 || status == 429 {
            throw PartyError(message: "The party token service didn't answer.", status: status)
        }
        guard (200..<300).contains(status), let value = json?["token"]?.string,
              let exp = json?["exp"]?.double else {
            throw PartyVerificationError(message: json?["error"]?.string ?? "Unable to connect. Please try again.")
        }
        token = (value, exp)
        return value
    }

    private func requestToken(captcha: String?) async throws -> (Int, JSONValue?) {
        var request = URLRequest(url: Party.site.appendingPathComponent("api/party/token"))
        request.timeoutInterval = 15
        if let captcha {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONBody.data(["captchaToken": captcha])
        }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, JSONValue.parse(data))
        } catch {
            throw PartyError(message: "no signal", status: 0)
        }
    }

    // MARK: Plumbing

    private func post(_ url: URL, _ body: [String: Any]) async -> (Int, JSONValue?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = JSONBody.data(body)
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, JSONValue.parse(data))
        } catch {
            return (0, nil)
        }
    }

    private func errorMessage(_ json: JSONValue?, _ status: Int) -> String {
        if let message = json?["error"]?.string { return message }
        return status != 0 ? "error \(status)" : "no signal"
    }

    private func isGuestTokenRejection(_ status: Int, _ json: JSONValue?) -> Bool {
        status == 401 && json?["code"]?.string == "guest-token"
    }

    /// POST with a guest token, retrying once when the token went stale.
    private func postWithToken(_ url: URL, _ body: [String: Any], interactive: Bool = true) async throws -> JSONValue {
        for attempt in 0..<2 {
            let token: String
            do {
                token = try await guestToken(interactive: interactive)
            } catch let error as PartyVerificationError {
                throw PartyError(message: error.message, status: 403, code: PartyError.verificationCode)
            } catch {
                throw PartyError(message: "no signal", status: 0)
            }
            var payload = body
            payload["guestToken"] = token
            let (status, json) = await post(url, payload)
            if attempt == 0 && isGuestTokenRejection(status, json) {
                self.token = nil
                continue
            }
            guard (200..<300).contains(status) else {
                throw PartyError(message: errorMessage(json, status), status: status,
                                 code: json?["code"]?.string, room: json?["room"]?.string)
            }
            return json ?? .object([:])
        }
        throw PartyError(message: "no signal", status: 0)
    }

    private func seatGrant(_ json: JSONValue, code: String?) throws -> SeatGrant {
        guard let playerId = json["playerId"]?.string, let playerKey = json["playerKey"]?.string,
              let code = json["code"]?.string ?? code else {
            throw PartyError(message: "something went wrong", status: 500)
        }
        return SeatGrant(code: code, playerId: playerId, playerKey: playerKey)
    }

    // MARK: Rooms

    func createRoom(name: String, character: String, isPrivate: Bool, replace: Bool = false) async throws -> SeatGrant {
        var body: [String: Any] = [
            "name": name, "character": character, "isPrivate": isPrivate,
            "seen": PartyStorage.seenCategories,
        ]
        if replace { body["replace"] = true }
        let json = try await postWithToken(Party.server.appendingPathComponent("rooms"), body)
        return try seatGrant(json, code: nil)
    }

    func joinRoom(code: String, name: String, character: String, playerKey: String? = nil,
                  replace: Bool = false) async throws -> SeatGrant {
        var body: [String: Any] = ["name": name, "character": character, "seen": PartyStorage.seenCategories]
        if let playerKey { body["playerKey"] = playerKey }
        if replace { body["replace"] = true }
        let url = Party.server.appendingPathComponent("rooms").appendingPathComponent(code).appendingPathComponent("join")
        let json = try await postWithToken(url, body)
        return try seatGrant(json, code: code)
    }

    /// `from`/`fromKey`: requeue from a table that is still waiting.
    /// `moveFrom`: "new table" after a game ended.
    func quickPlay(name: String, character: String, size: String, rated: Bool, replace: Bool = false,
                   from: String? = nil, fromKey: String? = nil, moveFrom: String? = nil) async throws -> QuickPlayResult {
        var body: [String: Any] = [
            "name": name, "character": character, "size": size, "rated": rated,
            "seen": PartyStorage.seenCategories,
        ]
        if replace { body["replace"] = true }
        if let from { body["from"] = from }
        if let fromKey { body["fromKey"] = fromKey }
        if let moveFrom { body["moveFrom"] = moveFrom }
        let json = try await postWithToken(Party.server.appendingPathComponent("quick-play"), body)
        if json["stay"]?.bool == true { return .stay }
        return .seated(try seatGrant(json, code: nil))
    }

    func myRating() async throws -> RatingInfo {
        let json = try await postWithToken(Party.server.appendingPathComponent("rating"), [:], interactive: false)
        return RatingInfo(json: json)
    }

    func listRooms(cursor: String?) async throws -> (rooms: [RoomSummary], nextCursor: String?) {
        var components = URLComponents(url: Party.server.appendingPathComponent("rooms"), resolvingAgainstBaseURL: false)!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let json = JSONValue.parse(data) else {
            throw PartyError(message: "error \(status)", status: status)
        }
        let rooms = (json["rooms"]?.array ?? []).compactMap(RoomSummary.init(json:))
        return (rooms, json["nextCursor"]?.string)
    }

    /// Loads `pages` pages of public rooms, de-duplicated by code.
    func listRoomPages(_ pages: Int) async throws -> (rooms: [RoomSummary], nextCursor: String?) {
        var seen = Set<String>()
        var rooms: [RoomSummary] = []
        var cursor: String?
        for _ in 0..<max(1, pages) {
            let page = try await listRooms(cursor: cursor)
            for room in page.rooms where !seen.contains(room.code) {
                seen.insert(room.code)
                rooms.append(room)
            }
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        return (rooms, cursor)
    }

    /// Number of people playing right now.
    func activity() async -> Int? {
        var request = URLRequest(url: Party.server.appendingPathComponent("activity"))
        request.timeoutInterval = 10
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let players = JSONValue.parse(result.0)?["players"]?.int, players >= 0 else { return nil }
        return players
    }

    /// HTTP fallback for room actions when the websocket isn't open.
    func actOverHTTP(code: String, playerKey: String, action: [String: Any]) async -> ActResult {
        let isLeave = action["type"] as? String == "leave"
        let url = Party.server.appendingPathComponent("rooms").appendingPathComponent(code).appendingPathComponent("act")
        for attempt in 0..<2 {
            let token: String
            do {
                token = try await guestToken(interactive: !isLeave)
            } catch {
                return ActResult(ok: false, error: "no signal", status: 0)
            }
            let (status, json) = await post(url, ["playerKey": playerKey, "action": action, "guestToken": token])
            if status == 0 { return ActResult(ok: false, error: "no signal", status: 0) }
            if attempt == 0 && isGuestTokenRejection(status, json) {
                self.token = nil
                continue
            }
            let ok = (200..<300).contains(status) && json?["ok"]?.bool != false
            return ActResult(ok: ok, error: json?["error"]?.string, submit: Self.submitResult(json?["submit"]),
                             status: status, room: json?["room"])
        }
        return ActResult(ok: false, error: "no signal", status: 0)
    }

    static func submitResult(_ json: JSONValue?) -> SubmitResult? {
        guard let json, json.object != nil else { return nil }
        return SubmitResult(accepted: json["accepted"]?.bool ?? false, why: json["why"]?.string)
    }

    // MARK: Feedback

    /// "how was that round?" Returns true when it was logged.
    func sendFeedback(gameId: String, rating: Int, notes: String?) async -> Bool {
        var body: [String: Any] = ["playerId": PartyStorage.feedbackPlayerId, "game": gameId, "rating": rating]
        if let notes, !notes.isEmpty { body["notes"] = notes }
        let (status, json) = await post(Party.site.appendingPathComponent("api/feedback"), body)
        guard status != 0 else { return false }
        return json?["ok"]?.bool == true || json?["reason"]?.string == "throttled"
    }
}
