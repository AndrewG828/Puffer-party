import Foundation

/// Endpoints and constants, mirrored from the krillion.io/party web client.
enum Party {
    /// Next.js site: issues guest tokens (`/api/party/token`) and takes feedback.
    static let site = URL(string: "https://krillion.io")!
    /// Realtime party server: rooms, quick play, rating, websockets.
    static let server = URL(string: "https://party.krillion.io")!
    /// Public invite links stay on the web so they work for everyone.
    static func inviteURL(_ code: String) -> URL {
        URL(string: "https://krillion.io/party/\(code)")!
    }

    static let categorySwapMs = 1300
    static let countdownMs = 3000
    static let maxChatLength = 160
    static let maxLives = 10
    static let maxMeterTarget = 5000
    static let maxNameLength = 16
    static let maxPlayers = 16
    static let meterFull = 600
    static let meterTargetStep = 50
    static let minPlayersToStart = 2
    static let popFreezeMs = 1500
    static let presencePingMs = 15000
    static let publicRoomPageSize = 50
    static let roomCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    static let roomCodeLength = 4
    static let roomIdleTimeoutMs = 1_800_000
    static let seatedElsewhere = "seated-elsewhere"
    static let seenCategoriesMax = 300
    static let seatHoldRefreshMs = 4000
    static let maxAnswerLength = 60

    static let drainMessage = "New games are paused while we work on improvements."
    static let pausedMessage = "Puffer Party is offline while we work on improvements."
    static let nameHelp = "2 to 16 letters, numbers or spaces"

    static let defaultSettings = RoomSettings(
        lives: 2, maxLives: 5, meterTarget: 600, minTurnMs: 8000,
        fuseMinMs: 10000, fuseMaxMs: 30000, maxPlayers: 6, isPrivate: false
    )

    /// Returns a cleaned display name, or nil when it isn't allowed.
    static func normalizeName(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let name = String(collapsed.prefix(maxNameLength))
        guard name.count >= 2 else { return nil }
        let ok = name.unicodeScalars.allSatisfy { s in
            s.properties.isAlphabetic || s.properties.numericType != nil
                || s == " " || s == "_" || s == "." || s == "'" || s == "-"
        }
        return ok ? name : nil
    }

    static func normalizeCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == roomCodeLength,
              code.allSatisfy({ roomCodeAlphabet.contains($0) }) else { return nil }
        return code
    }

    /// FNV-1a over UTF-16 code units, base 36: the web's `categoryKey`.
    static func categoryKey(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var hash: UInt32 = 0x811c9dc5
        for unit in cleaned.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 36)
    }
}

struct QuickPlayTable: Equatable {
    let id: String
    let label: String
    let min: Int
    let max: Int
    let gatherMs: Int
    let hint: String

    static let all: [QuickPlayTable] = [
        .init(id: "duel", label: "1V1", min: 2, max: 2, gatherMs: 0, hint: "one on one"),
        .init(id: "trio", label: "3S", min: 3, max: 3, gatherMs: 0, hint: "three at a table"),
        .init(id: "party", label: "4–6", min: 4, max: 6, gatherMs: 15000, hint: "4 to 6 players"),
        .init(id: "crowd", label: "8–10", min: 8, max: 10, gatherMs: 20000, hint: "8 to 10 players"),
    ]
    static let defaultId = "party"

    static func table(_ id: String?) -> QuickPlayTable? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

struct Tier: Equatable {
    let id: String
    let name: String
    let label: String
    let score: Int
    let emoji: String
    let colorHex: UInt32
    let rank: Int

    static let all: [Tier] = [
        .init(id: "plankton", name: "Plankton", label: "PLANKTON", score: 10, emoji: "🫧", colorHex: 0x8fa3c4, rank: 0),
        .init(id: "tooclever", name: "Too Clever", label: "TOO CLEVER", score: 15, emoji: "🤡", colorHex: 0xff9f43, rank: 0),
        .init(id: "schooler", name: "Schooler", label: "SCHOOLER", score: 30, emoji: "🐟", colorHex: 0x4de3ff, rank: 1),
        .init(id: "rare", name: "Rare", label: "RARE", score: 60, emoji: "🦑", colorHex: 0xff5252, rank: 2),
        .init(id: "deepcut", name: "Deep Cut", label: "DEEP CUT", score: 85, emoji: "🏮", colorHex: 0x9d7bff, rank: 3),
        .init(id: "krillion", name: "One in a Krillion", label: "ONE IN A KRILLION", score: 100, emoji: "🌟", colorHex: 0xffd166, rank: 4),
    ]

    static func find(_ id: String?) -> Tier? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Meter points an answer of this tier adds (METER_BY_TIER).
    static func meterPoints(_ id: String?) -> Int {
        find(id)?.score ?? 0
    }

    /// Asset name of the tier badge image.
    var imageName: String { "tier-\(id)" }
}
