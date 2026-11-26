import Foundation

struct RoomSettings: Equatable {
    var lives: Int
    var maxLives: Int
    var meterTarget: Int
    var minTurnMs: Int
    var fuseMinMs: Int
    var fuseMaxMs: Int
    var maxPlayers: Int
    var isPrivate: Bool

    init(lives: Int, maxLives: Int, meterTarget: Int, minTurnMs: Int,
         fuseMinMs: Int, fuseMaxMs: Int, maxPlayers: Int, isPrivate: Bool) {
        self.lives = lives
        self.maxLives = maxLives
        self.meterTarget = meterTarget
        self.minTurnMs = minTurnMs
        self.fuseMinMs = fuseMinMs
        self.fuseMaxMs = fuseMaxMs
        self.maxPlayers = maxPlayers
        self.isPrivate = isPrivate
    }

    init(json: JSONValue?) {
        let d = Party.defaultSettings
        lives = json?["lives"]?.int ?? d.lives
        maxLives = json?["maxLives"]?.int ?? d.maxLives
        meterTarget = max(1, json?["meterTarget"]?.int ?? d.meterTarget)
        minTurnMs = json?["minTurnMs"]?.int ?? d.minTurnMs
        fuseMinMs = json?["fuseMinMs"]?.int ?? d.fuseMinMs
        fuseMaxMs = json?["fuseMaxMs"]?.int ?? d.fuseMaxMs
        maxPlayers = json?["maxPlayers"]?.int ?? d.maxPlayers
        isPrivate = json?["isPrivate"]?.bool ?? d.isPrivate
    }
}

struct LastAnswer: Equatable {
    let text: String
    let tier: String?
}

struct Player: Identifiable, Equatable {
    let id: String
    let name: String
    let character: String
    let seat: Int
    let isHost: Bool
    let connected: Bool
    let lives: Int
    let meter: Int
    let alive: Bool
    let answers: Int
    let pops: Int
    let best: String?
    let typing: String?
    let lastAnswer: LastAnswer?
    let place: Int?
    /// `nil` means "not reported", which the web treats as ready.
    let ready: Bool?
    let autoJoin: Bool
    let observer: Bool
    let removed: Bool
    let chatMuted: Bool
    let rating: Double?
    let ratingDelta: Int?

    var isReady: Bool { ready != false }

    init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? "?"
        character = json["character"]?.string ?? Buddy.defaultId
        seat = json["seat"]?.int ?? 0
        isHost = json["isHost"]?.bool ?? false
        connected = json["connected"]?.bool ?? true
        lives = json["lives"]?.int ?? 0
        meter = json["meter"]?.int ?? 0
        alive = json["alive"]?.bool ?? false
        answers = json["answers"]?.int ?? 0
        pops = json["pops"]?.int ?? 0
        best = json["best"]?.string
        typing = json["typing"]?.string
        if let last = json["lastAnswer"], let text = last["text"]?.string {
            lastAnswer = LastAnswer(text: text, tier: last["tier"]?.string)
        } else {
            lastAnswer = nil
        }
        place = json["place"]?.int
        ready = json["ready"]?.bool
        autoJoin = json["autoJoin"]?.bool ?? false
        observer = json["observer"]?.bool ?? false
        removed = json["removed"]?.bool ?? false
        chatMuted = json["chatMuted"]?.bool ?? false
        rating = json["rating"]?.double
        ratingDelta = json["ratingDelta"]?.int
    }
}

struct RoomCategory: Equatable {
    let index: Int
    let text: String
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int
    let at: Double
    let playerId: String?
    let name: String
    let text: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.int else { return nil }
        self.id = id
        at = json["at"]?.double ?? 0
        playerId = json["playerId"]?.string
        name = json["name"]?.string ?? ""
        text = json["text"]?.string ?? ""
    }
}

/// One entry of the room's event log. Kinds: join, countdown, start,
/// category, pass, reject, spare, pop, out, win, lobby.
struct RoomEvent: Equatable {
    let seq: Int
    let at: Double
    let kind: String
    let raw: JSONValue

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.string else { return nil }
        self.kind = kind
        seq = json["seq"]?.int ?? 0
        at = json["at"]?.double ?? 0
        raw = json
    }

    var playerId: String? { raw["playerId"]?.string }
    var from: String? { raw["from"]?.string }
    var to: String? { raw["to"]?.string }
    var answer: String? { raw["answer"]?.string }
    var tier: String? { raw["tier"]?.string }
    var text: String? { raw["text"]?.string }
    var why: String? { raw["why"]?.string }
    var index: Int? { raw["index"]?.int }
    var livesLeft: Int { raw["livesLeft"]?.int ?? 0 }
}

enum RoomPhase: String {
    case lobby, countdown, round, over
}

struct Room: Equatable {
    let code: String
    let version: Int
    let phase: RoomPhase
    let settings: RoomSettings
    let hostId: String
    /// Sorted by seat.
    let players: [Player]
    let holderId: String?
    /// Server-clock milliseconds.
    let holderSince: Double?
    let category: RoomCategory?
    let countdownEndsAt: Double?
    let gatherEndsAt: Double?
    let winnerId: String?
    let gameNumber: Int
    let gameId: String?
    let queue: String?
    let rated: Bool
    let chatEnabled: Bool
    let events: [RoomEvent]
    let chat: [ChatMessage]
    /// Server clock (ms) when this version was produced.
    let now: Double

    init?(json: JSONValue) {
        guard let code = json["code"]?.string else { return nil }
        self.code = code
        version = json["version"]?.int ?? 0
        phase = RoomPhase(rawValue: json["phase"]?.string ?? "lobby") ?? .lobby
        settings = RoomSettings(json: json["settings"])
        hostId = json["hostId"]?.string ?? ""
        players = (json["players"]?.array ?? []).compactMap(Player.init(json:)).sorted { $0.seat < $1.seat }
        holderId = json["holderId"]?.string
        holderSince = json["holderSince"]?.double
        if let c = json["category"], let text = c["text"]?.string {
            category = RoomCategory(index: c["index"]?.int ?? 1, text: text)
        } else {
            category = nil
        }
        countdownEndsAt = json["countdownEndsAt"]?.double
        gatherEndsAt = json["gatherEndsAt"]?.double
        winnerId = json["winnerId"]?.string
        gameNumber = json["gameNumber"]?.int ?? 0
        gameId = json["gameId"]?.string
        queue = json["queue"]?.string
        rated = json["rated"]?.bool ?? false
        chatEnabled = json["chatEnabled"]?.bool ?? true
        events = (json["events"]?.array ?? []).compactMap(RoomEvent.init(json:))
        chat = (json["chat"]?.array ?? []).compactMap(ChatMessage.init(json:))
        now = json["now"]?.double ?? 0
    }

    func player(_ id: String?) -> Player? {
        guard let id else { return nil }
        return players.first { $0.id == id }
    }

    var table: QuickPlayTable? { QuickPlayTable.table(queue) }
}

/// Row of the public room list.
struct RoomSummary: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let hostName: String
    let players: Int
    let maxPlayers: Int
    let phase: String
    let queue: String?
    let rated: Bool

    init?(json: JSONValue) {
        guard let code = json["code"]?.string else { return nil }
        self.code = code
        hostName = json["hostName"]?.string ?? ""
        players = json["players"]?.int ?? 0
        maxPlayers = json["maxPlayers"]?.int ?? 0
        phase = json["phase"]?.string ?? "lobby"
        queue = json["queue"]?.string
        rated = json["rated"]?.bool ?? false
    }

    var isFull: Bool { players >= maxPlayers }
}

struct RatingRecent: Equatable {
    let gameId: String
    let delta: Int
}

struct PlayerRating: Equatable {
    let rating: Double
    let games: Int
    let wins: Int
    let peak: Double
    let recent: [RatingRecent]
}

struct RatingInfo: Equatable {
    let rating: PlayerRating?
    let account: Bool
    let merged: Int

    init(json: JSONValue) {
        if let r = json["rating"], let value = r["rating"]?.double {
            rating = PlayerRating(
                rating: value,
                games: r["games"]?.int ?? 0,
                wins: r["wins"]?.int ?? 0,
                peak: r["peak"]?.double ?? value,
                recent: (r["recent"]?.array ?? []).compactMap { e in
                    guard let id = e["gameId"]?.string else { return nil }
                    return RatingRecent(gameId: id, delta: e["delta"]?.int ?? 0)
                }
            )
        } else {
            rating = nil
        }
        account = json["account"]?.bool ?? false
        merged = json["merged"]?.int ?? 0
    }
}

/// What the app keeps to get back into a room.
struct Seat: Codable, Hashable {
    var playerId: String
    var playerKey: String
    var name: String
    var character: String
}

func formatRating(_ value: Double) -> String {
    String(Int(value.rounded()))
}
