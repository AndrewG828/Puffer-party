import Foundation

/// Local persistence, using the same keys as the web client's localStorage.
enum PartyStorage {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let name = "krillion-party-name"
        static let character = "krillion-party-character"
        static let seen = "krillion-party-seen"
        static let size = "krillion-party-size"
        static let seatPrefix = "krillion-party-seat:"
        static let muted = "krillion-party-muted"
        static let pendingRatings = "krillion:party:pending-ratings"
        static let feedbackPlayer = "krillion-player-id"
        static let maxStreak = "krillion-max-streak"
        static let howToPlaySeen = "krillion-party-howto-seen"
    }

    // MARK: Identity

    static var name: String {
        get { defaults.string(forKey: Key.name) ?? "" }
        set { defaults.set(newValue, forKey: Key.name) }
    }

    /// Longest daily streak. Buddies unlock at the same streaks as on the web.
    static var maxStreak: Int {
        get { defaults.integer(forKey: Key.maxStreak) }
        set { defaults.set(newValue, forKey: Key.maxStreak) }
    }

    static var character: String {
        get {
            let saved = defaults.string(forKey: Key.character)
            let buddy = Buddy.find(saved)
            return Buddy.isValid(saved) && buddy.isUnlocked(streak: maxStreak) ? buddy.id : Buddy.defaultId
        }
        set { defaults.set(newValue, forKey: Key.character) }
    }

    static var quickPlaySize: String {
        get {
            let saved = defaults.string(forKey: Key.size)
            return QuickPlayTable.table(saved) != nil ? saved! : QuickPlayTable.defaultId
        }
        set { defaults.set(newValue, forKey: Key.size) }
    }

    static var howToPlaySeen: Bool {
        get { defaults.bool(forKey: Key.howToPlaySeen) }
        set { defaults.set(newValue, forKey: Key.howToPlaySeen) }
    }

    /// Stable anonymous id sent with round feedback.
    static var feedbackPlayerId: String {
        if let id = defaults.string(forKey: Key.feedbackPlayer) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Key.feedbackPlayer)
        return id
    }

    // MARK: Seen categories

    /// Keys of categories already played, so the server can avoid repeats.
    static var seenCategories: [String] {
        let list = defaults.stringArray(forKey: Key.seen) ?? []
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyz")
        let valid = list.filter { key in
            !key.isEmpty && key.count <= 7 && key.allSatisfy { allowed.contains($0) }
        }
        return Array(valid.suffix(Party.seenCategoriesMax))
    }

    static func rememberCategory(_ text: String) {
        let key = Party.categoryKey(text)
        var list = seenCategories.filter { $0 != key }
        list.append(key)
        defaults.set(Array(list.suffix(Party.seenCategoriesMax)), forKey: Key.seen)
    }

    // MARK: Seats

    private struct HeldSeat: Codable {
        var seat: Seat
        var heldAt: Date
    }

    static func saveSeat(_ code: String, _ seat: Seat) {
        let held = HeldSeat(seat: seat, heldAt: Date())
        if let data = try? JSONEncoder().encode(held) {
            defaults.set(data, forKey: Key.seatPrefix + code)
        }
    }

    /// Keeps the seat fresh while the player is in the room.
    static func holdSeat(_ code: String, _ seat: Seat) {
        saveSeat(code, seat)
    }

    static func loadSeat(_ code: String) -> Seat? {
        guard let data = defaults.data(forKey: Key.seatPrefix + code),
              let held = try? JSONDecoder().decode(HeldSeat.self, from: data) else { return nil }
        if Date().timeIntervalSince(held.heldAt) * 1000 > Double(Party.roomIdleTimeoutMs) {
            clearSeat(code)
            return nil
        }
        return held.seat
    }

    static func clearSeat(_ code: String) {
        defaults.removeObject(forKey: Key.seatPrefix + code)
    }

    /// Most recent room the player still holds a seat in.
    static func latestHeldSeat() -> (code: String, seat: Seat)? {
        var best: (String, Seat, Date)?
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Key.seatPrefix) {
            guard let data = value as? Data,
                  let held = try? JSONDecoder().decode(HeldSeat.self, from: data) else { continue }
            let code = String(key.dropFirst(Key.seatPrefix.count))
            if Date().timeIntervalSince(held.heldAt) * 1000 > Double(Party.roomIdleTimeoutMs) {
                clearSeat(code)
                continue
            }
            if best == nil || held.heldAt > best!.2 { best = (code, held.seat, held.heldAt) }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: Muted players (local only)

    static var muted: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.muted) ?? []) }
        set { defaults.set(Array(newValue.suffix(500)), forKey: Key.muted) }
    }

    // MARK: Pending ratings

    struct PendingRating: Codable, Equatable {
        let gameId: String
        let at: Date
    }

    static var pendingRatings: [PendingRating] {
        get {
            guard let data = defaults.data(forKey: Key.pendingRatings),
                  let list = try? JSONDecoder().decode([PendingRating].self, from: data) else { return [] }
            let cutoff = Date().addingTimeInterval(-86_400)
            return Array(list.filter { $0.at > cutoff && $0.at <= Date() && $0.gameId.count < 200 }.suffix(20))
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue.suffix(20))) {
                defaults.set(data, forKey: Key.pendingRatings)
            }
        }
    }

    /// Called when leaving a rated game, so the Elo change can be shown later.
    static func rememberLeavingRating(room: Room?, playerId: String) {
        guard let room, room.rated, let gameId = room.gameId,
              let me = room.player(playerId), me.rating != nil,
              room.phase == .round || room.phase == .over,
              me.alive || me.place != nil else { return }
        pendingRatings = pendingRatings.filter { $0.gameId != gameId } + [PendingRating(gameId: gameId, at: Date())]
    }
}
