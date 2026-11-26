import Foundation
import Observation

/// Category card shown at the top of the round.
struct CategoryCard: Equatable {
    let index: Int
    let text: String
    var cleared = false
    var leaving = false
    /// "new" for a few seconds after the category changes.
    var tag: String?
}

struct RejectNotice: Equatable {
    let text: String
    let why: String?
    let key: Int

    var message: String {
        why == "repeat" ? "“\(text)”: already said" : "“\(text)”: no echo. keep going"
    }
}

struct WinnerNotice: Equatable {
    let playerId: String?
    let key: Int
}

/// Everything about one room: getting a seat, the live connection and the
/// game state the UI renders. Ports the web room page and game component.
@MainActor
@Observable
final class RoomSession {
    enum Screen: Equatable {
        /// Ask for a name/buddy before taking a seat ("JOIN THE RING").
        case joinForm
        /// Reclaiming a stored seat.
        case swimmingIn
        case playing
        /// Terminal message with a way back ("ROOM ABCD").
        case message(String)
        case paused
        case leaving
        case findingTable
    }

    private(set) var code: String
    private(set) var screen: Screen = .swimmingIn
    private(set) var seat: Seat?
    private(set) var stream: RoomConnection.Status = .connecting
    private(set) var room: Room?
    /// Server clock minus local clock, in milliseconds.
    private(set) var clockOffset: Double = 0

    // Join form
    var joinError: String?
    var joinSeatedElsewhere: String?
    private(set) var joining = false

    // Game presentation
    private(set) var card: CategoryCard?
    private(set) var categoryCleared = false
    private(set) var outNotice: String?
    private(set) var winner: WinnerNotice?
    private(set) var reject: RejectNotice?
    private(set) var inputLocked = false
    private(set) var segments: [String: [MeterSegment]] = [:]
    /// Answers each player passed with in the current category.
    private(set) var answerChips: [String: LastAnswer] = [:]
    /// Text a player just had rejected, shown briefly over their seat.
    private(set) var rejectChips: [String: String] = [:]
    private(set) var popKeys: [String: Int] = [:]
    private(set) var spareKeys: [String: Int] = [:]
    private(set) var thresholds = PufferLevel.baseThresholds
    /// Bumped when it becomes my turn, so the view can focus the answer box.
    private(set) var myTurnKey = 0

    // Answer box
    private(set) var answer = ""
    private(set) var sending = false

    // Chat
    private(set) var lastReadChatId = 0
    var muted: Set<String> = PartyStorage.muted
    var findingTable = false

    var onExit: (() -> Void)?

    @ObservationIgnored private var connection: RoomConnection?
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    @ObservationIgnored private var requeueTimer: Task<Void, Never>?
    @ObservationIgnored private var lockTimer: Task<Void, Never>?
    @ObservationIgnored private var liveResetTimer: Task<Void, Never>?
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lostSeatAttempts = 0
    @ObservationIgnored private var lostSeatPending = false
    @ObservationIgnored private var rejoinGeneration = 0
    @ObservationIgnored private var seenSeq: Int?
    @ObservationIgnored private var gameNumber = 0
    @ObservationIgnored private var cardIndex = 0
    @ObservationIgnored private var frozen = false
    @ObservationIgnored private var lastHolderKey: String?
    @ObservationIgnored private var lastTurnKey: String?
    @ObservationIgnored private var noticeKey = 0
    @ObservationIgnored private var lastRememberedCategory: String?
    @ObservationIgnored private var holderKeyForThresholds: Double?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var submitRevision: Int?
    @ObservationIgnored private var telemetry = InputTelemetry()
    @ObservationIgnored private var typing: TypingThrottle!
    @ObservationIgnored private var started = false

    /// `grant`: a seat the lobby just obtained, so no re-join is needed.
    init(code: String, grant: Seat? = nil) {
        self.code = code
        if let grant {
            seat = grant
            screen = .playing
        }
        typing = TypingThrottle { [weak self] text in
            guard let self else { return }
            _ = await self.act(["type": "typing", "text": text])
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if let seat {
            PartyStorage.saveSeat(code, seat)
            connect(seat)
        } else if let stored = PartyStorage.loadSeat(code) {
            rejoin(stored)
        } else {
            screen = .joinForm
        }
    }

    func stop() {
        teardownConnection()
        typing.stop()
        requeueTimer?.cancel()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        started = false
    }

    /// The app came back to the foreground: make sure the socket is alive.
    func resumed() {
        connection?.ping()
    }

    private func teardownConnection() {
        connection?.close()
        connection = nil
        holdTimer?.cancel()
        holdTimer = nil
        liveResetTimer?.cancel()
        lockTimer?.cancel()
    }

    // MARK: Seats

    /// Join from the "JOIN THE RING" form.
    func joinFromForm(name rawName: String, character: String, replace: Bool = false) {
        guard let name = Party.normalizeName(rawName) else {
            joinError = Party.nameHelp
            joinSeatedElsewhere = nil
            return
        }
        guard !joining else { return }
        joining = true
        joinError = nil
        joinSeatedElsewhere = nil
        Task {
            defer { joining = false }
            do {
                let grant = try await PartyAPI.shared.joinRoom(code: code, name: name, character: character, replace: replace)
                PartyStorage.name = name
                let newSeat = Seat(playerId: grant.playerId, playerKey: grant.playerKey, name: name, character: character)
                PartyStorage.saveSeat(code, newSeat)
                seat = newSeat
                screen = .playing
                connect(newSeat)
            } catch let error as PartyError {
                joinError = error.displayText(code: code)
                joinSeatedElsewhere = error.seatedElsewhereRoom
            } catch {
                joinError = "something went wrong"
            }
        }
    }

    private func rejoin(_ stored: Seat) {
        screen = .swimmingIn
        rejoinGeneration += 1
        let generation = rejoinGeneration
        let delays = [1000, 2000, 4000, 8000, 15000, 15000]
        Task {
            var attempt = 0
            while generation == rejoinGeneration {
                do {
                    let grant = try await PartyAPI.shared.joinRoom(
                        code: code, name: stored.name, character: stored.character, playerKey: stored.playerKey)
                    guard generation == rejoinGeneration else { return }
                    var next = stored
                    next.playerId = grant.playerId
                    next.playerKey = grant.playerKey
                    if next != stored { PartyStorage.saveSeat(code, next) }
                    lostSeatPending = false
                    seat = next
                    screen = .playing
                    connect(next)
                    return
                } catch let error as PartyError {
                    guard generation == rejoinGeneration else { return }
                    if error.status == 410 {
                        screen = .paused
                    } else if error.status == 404 {
                        screen = .message("no room \(code) here. it may have closed")
                    } else if error.code == PartyError.verificationCode {
                        screen = .message("a quick check is needed to keep playing. try again")
                    } else if error.isPassing {
                        if attempt < delays.count {
                            try? await Task.sleep(nanoseconds: UInt64(delays[attempt]) * 1_000_000)
                            attempt += 1
                            continue
                        }
                        screen = .message(error.status == 0
                            ? "no signal. try again"
                            : "couldn't reach your seat. try again")
                    } else {
                        lostSeatPending = false
                        PartyStorage.clearSeat(code)
                        joinError = error.displayText(code: code)
                        screen = .joinForm
                    }
                    return
                } catch {
                    screen = .message("something went wrong")
                    return
                }
            }
        }
    }

    /// Our seat vanished from the room: try to take it back a few times.
    private func lostSeat() {
        guard !lostSeatPending else { return }
        if lostSeatAttempts >= 4 {
            teardownConnection()
            screen = .message("lost your seat. try again")
            return
        }
        lostSeatAttempts += 1
        lostSeatPending = true
        let stored = seat ?? PartyStorage.loadSeat(code)
        teardownConnection()
        seat = nil
        if let stored {
            rejoin(stored)
        } else {
            screen = .joinForm
        }
    }

    /// Tries the stored seat again after a terminal message.
    func retry() {
        lostSeatAttempts = 0
        lostSeatPending = false
        if let stored = PartyStorage.loadSeat(code) {
            rejoin(stored)
        } else {
            screen = .joinForm
        }
    }

    private func connect(_ seat: Seat) {
        teardownConnection()
        resetGameState()
        let conn = RoomConnection(code: code, playerKey: seat.playerKey)
        conn.onRoom = { [weak self] json in self?.handleRoom(json) }
        conn.onStatus = { [weak self] status in self?.handleStatus(status) }
        connection = conn
        stream = .connecting
        conn.start()

        PartyStorage.holdSeat(code, seat)
        let roomCode = code
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Party.seatHoldRefreshMs) * 1_000_000)
                guard let self, let seat = self.seat, self.code == roomCode else { return }
                PartyStorage.holdSeat(roomCode, seat)
            }
        }
        startRequeueTimer()
    }

    private func handleStatus(_ status: RoomConnection.Status) {
        stream = status
        switch status {
        case .refused:
            Task { @MainActor in self.lostSeat() }
        case .live:
            liveResetTimer?.cancel()
            liveResetTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.lostSeatAttempts = 0
            }
        case .paused:
            screen = .paused
        case .gone:
            screen = .message("this room closed")
        case .removed:
            PartyStorage.clearSeat(code)
            screen = .message(connection?.removalMessage ?? "The host removed or banned you from this room.")
        case .connecting, .reconnecting:
            break
        }
    }

    // MARK: Actions

    /// Sends an action over the socket, falling back to HTTP.
    func act(_ action: [String: Any]) async -> ActResult {
        guard let seat else { return ActResult(ok: false, error: "no seat", status: 0) }
        let key = seat.playerKey
        let isLeave = action["type"] as? String == "leave"
        var result: ActResult
        if let connection {
            result = await connection.act(action)
            if result.status == -1 || (isLeave && result.status == 0) {
                result = await PartyAPI.shared.actOverHTTP(code: code, playerKey: key, action: action)
            }
        } else {
            result = await PartyAPI.shared.actOverHTTP(code: code, playerKey: key, action: action)
        }
        if result.status == 403 && result.error == "You are not in this room." && self.seat?.playerKey == key {
            lostSeat()
        }
        if let json = result.room { handleRoom(json) }
        return result
    }

    func send(_ action: [String: Any]) {
        Task { _ = await act(action) }
    }

    func startGame() { send(["type": "start"]) }
    func playAgain() { send(["type": "again"]) }
    func setAutoJoin(_ enabled: Bool) { send(["type": "auto-join", "enabled": enabled]) }
    func updateSettings(_ patch: [String: Any]) { send(["type": "settings", "settings": patch]) }

    func leave() {
        if let seat { PartyStorage.rememberLeavingRating(room: room, playerId: seat.playerId) }
        screen = .leaving
        if seat != nil {
            let leaving = connection
            Task {
                _ = await act(["type": "leave"])
                leaving?.close()
            }
        }
        PartyStorage.clearSeat(code)
        typing.stop()
        onExit?()
    }

    /// "NEW TABLE" / "NEW OPPONENT" after a quick-play game.
    func findGame() {
        guard let seat, let room, let queue = room.queue, !findingTable else { return }
        findingTable = true
        screen = .findingTable
        Task {
            do {
                let result = try await PartyAPI.shared.quickPlay(
                    name: seat.name, character: seat.character, size: queue, rated: room.rated,
                    fromKey: seat.playerKey, moveFrom: code)
                findingTable = false
                switch result {
                case .stay: screen = .playing
                case .seated(let grant): move(to: grant, from: seat)
                }
            } catch let error as PartyError {
                findingTable = false
                screen = .playing
                joinError = error.displayText()
            } catch {
                findingTable = false
                screen = .playing
            }
        }
    }

    /// Leaves this room and takes the seat in another one.
    private func move(to grant: SeatGrant, from old: Seat) {
        PartyStorage.rememberLeavingRating(room: room, playerId: old.playerId)
        let oldCode = code
        let oldKey = old.playerKey
        Task { _ = await PartyAPI.shared.actOverHTTP(code: oldCode, playerKey: oldKey, action: ["type": "leave"]) }
        PartyStorage.clearSeat(oldCode)
        let next = Seat(playerId: grant.playerId, playerKey: grant.playerKey, name: old.name, character: old.character)
        teardownConnection()
        code = grant.code
        seat = next
        PartyStorage.saveSeat(code, next)
        screen = .playing
        connect(next)
    }

    /// Quick-play tables that can't fill up look for a better table every 6s.
    private func startRequeueTimer() {
        requeueTimer?.cancel()
        requeueTimer = Task { [weak self] in
            var busy = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !busy, let seat = self.seat, let room = self.room,
                      let table = room.table, room.phase == .lobby else { continue }
                let ready = room.players.filter { $0.isReady && $0.connected }
                guard let me = room.player(seat.playerId), me.isReady, room.gatherEndsAt == nil,
                      ready.count < table.min else { continue }
                busy = true
                let from = self.code
                if let result = try? await PartyAPI.shared.quickPlay(
                    name: seat.name, character: seat.character, size: table.id, rated: room.rated,
                    from: from, fromKey: seat.playerKey),
                   case .seated(let grant) = result, self.code == from {
                    self.move(to: grant, from: seat)
                    return
                }
                busy = false
            }
        }
    }

    // MARK: Answer box

    var me: Player? { room?.player(seat?.playerId) }

    var isMyTurn: Bool {
        guard let room, room.phase == .round, let seat, room.holderId == seat.playerId,
              me?.alive == true else { return false }
        return !inputLocked
    }

    var canType: Bool {
        room?.phase == .round && me?.alive == true
    }

    /// Called by the answer field for every edit.
    func answerEdited(newText: String, inserted: String, removedLength: Int) {
        let text = String(newText.prefix(Party.maxAnswerLength))
        telemetry.note(inserted: inserted, removedLength: removedLength,
                       timestamp: ProcessInfo.processInfo.systemUptime * 1000, resultingText: text)
        revision += 1
        answer = text
        if isMyTurn && submitRevision == nil { typing.update(text) }
    }

    func submit() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMyTurn, submitRevision == nil, !text.isEmpty else { return }
        submitRevision = revision
        typing.clear()
        sending = true
        let report = telemetry.report()
        Task {
            let result = await act(["type": "submit", "text": text, "input": report])
            if result.submit?.accepted == true || result.submit?.why == "miss" || result.submit?.why == "repeat" {
                clearAnswerIfUnchanged()
            }
            submitRevision = nil
            sending = false
            if let room, room.phase == .round, room.holderId == seat?.playerId, !answer.isEmpty {
                typing.update(answer)
            }
        }
    }

    private func clearAnswerIfUnchanged() {
        guard let pending = submitRevision, pending == revision else { return }
        revision += 1
        answer = ""
        typing.clear()
        telemetry.reset()
    }

    // MARK: Room updates

    private func resetGameState() {
        room = nil
        seenSeq = nil
        gameNumber = 0
        cardIndex = 0
        frozen = false
        card = nil
        categoryCleared = false
        outNotice = nil
        winner = nil
        reject = nil
        segments = [:]
        answerChips = [:]
        rejectChips = [:]
        lastHolderKey = nil
        lastTurnKey = nil
        lastReadChatId = 0
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    private func handleRoom(_ json: JSONValue) {
        guard let next = Room(json: json), next.code == code else { return }
        if let current = room, current.code == next.code, next.version <= current.version { return }
        let isFirst = room == nil
        let offset = next.now - Date().timeIntervalSince1970 * 1000
        clockOffset = offset

        let lastSeq = next.events.last?.seq ?? 0
        var fresh: [RoomEvent] = []
        if next.gameNumber != gameNumber {
            gameNumber = next.gameNumber
            segments = [:]
            cardIndex = 0
        }
        if let seen = seenSeq {
            fresh = next.events.filter { $0.seq > seen }
            seenSeq = max(seen, lastSeq)
        } else {
            for event in eventsSinceGameStart(next.events) where event.kind == "pass" {
                if let from = event.from { segments[from] = HeartMeter.feed(segments[from] ?? [], tier: event.tier) }
            }
            seenSeq = lastSeq
        }
        if next.phase == .lobby { segments = [:] }

        let previous = room
        room = next

        // Removal / lost seat checks.
        if let seat {
            if next.players.contains(where: { $0.id == seat.playerId && $0.removed }) {
                PartyStorage.clearSeat(code)
                teardownConnection()
                screen = .message("The host removed you from this room.")
                return
            }
            if !next.players.contains(where: { $0.id == seat.playerId }) {
                lostSeat()
                return
            }
        }

        playEffects(next, fresh, isFirst: isFirst)
        for event in fresh where event.kind != "join" { handle(event, in: next) }

        for player in next.players {
            segments[player.id] = HeartMeter.reconcile(segments[player.id] ?? [], meter: player.meter,
                                                        target: next.settings.meterTarget)
        }

        if !frozen {
            let sameCategory = next.phase == .round && next.category?.index == cardIndex
            let made = makeCard(next)
            if !(sameCategory && card != nil) { card = made }
        }

        if next.phase == .over, !fresh.contains(where: { $0.kind == "win" }), lastHolderKey != "__over" {
            if winner == nil {
                noticeKey += 1
                winner = WinnerNotice(playerId: next.winnerId, key: noticeKey)
            }
        }

        // Category memory (so the server avoids repeats for us).
        if next.phase == .round, let text = next.category?.text, text != lastRememberedCategory {
            lastRememberedCategory = text
            PartyStorage.rememberCategory(text)
        }

        // Turn tracking.
        if next.holderSince != holderKeyForThresholds {
            holderKeyForThresholds = next.holderSince
            thresholds = PufferLevel.thresholds(holderSince: next.holderSince)
        }
        let myId = seat?.playerId
        if next.phase == .round, next.holderId == myId, lastHolderKey != myId {
            myTurnKey += 1
            // Show what was pre-typed to the ring right away.
            if !answer.isEmpty, submitRevision == nil { typing.update(answer) }
        }
        lastHolderKey = next.phase == .over ? "__over" : next.holderId
        if next.holderId != myId || next.phase != .round { typing.clear() }

        lockTimer?.cancel()
        let wait = next.phase == .round && next.holderSince != nil
            ? next.holderSince! - offset - Date().timeIntervalSince1970 * 1000 : 0
        if wait > 0 {
            inputLocked = true
            lockTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait + 30) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.inputLocked = false
            }
        } else {
            inputLocked = false
        }

        if previous == nil, let seat, next.players.contains(where: { $0.id == seat.playerId }) {
            lostSeatPending = false
        }
    }

    private func eventsSinceGameStart(_ events: [RoomEvent]) -> [RoomEvent] {
        for i in stride(from: events.count - 1, through: 0, by: -1) {
            if events[i].kind == "start" { return Array(events[i...]) }
            if events[i].kind == "lobby" { return Array(events[(i + 1)...]) }
        }
        return events
    }

    private func makeCard(_ room: Room) -> CategoryCard? {
        guard room.phase == .round, let category = room.category else { return nil }
        let tag: String? = cardIndex != 0 && category.index != cardIndex ? "new" : nil
        cardIndex = category.index
        if tag != nil {
            Haptics.category()
            let index = category.index
            after(3200) { session in
                if session.card?.index == index, session.card?.tag == "new" { session.card?.tag = nil }
            }
        }
        return CategoryCard(index: category.index, text: category.text, tag: tag)
    }

    private func unfreeze() {
        frozen = false
        categoryCleared = false
        if let room { card = makeCard(room) }
    }

    private func handle(_ event: RoomEvent, in room: Room) {
        let myId = seat?.playerId
        switch event.kind {
        case "pass":
            guard let from = event.from else { return }
            answerChips[from] = LastAnswer(text: event.answer ?? "", tier: event.tier)
            segments[from] = HeartMeter.feed(segments[from] ?? [], tier: event.tier)
            if from == myId {
                clearAnswerAfterPass()
                reject = nil
            }
        case "reject":
            guard let playerId = event.playerId else { return }
            if !muted.contains(playerId) {
                rejectChips[playerId] = event.text ?? ""
                after(1600) { session in session.rejectChips[playerId] = nil }
            }
            if playerId == myId {
                noticeKey += 1
                let key = noticeKey
                reject = RejectNotice(text: event.text ?? "", why: event.why, key: key)
                clearAnswerAfterPass()
                after(2200) { session in if session.reject?.key == key { session.reject = nil } }
            }
        case "spare":
            if let playerId = event.playerId {
                noticeKey += 1
                spareKeys[playerId] = noticeKey
            }
        case "pop":
            guard let playerId = event.playerId else { return }
            let out = event.livesLeft <= 0
            noticeKey += 1
            popKeys[playerId] = noticeKey
            if room.phase != .round || room.category?.index != cardIndex {
                frozen = true
                card = nil
                after(out ? 900 : Party.popFreezeMs, force: true) { session in session.unfreeze() }
            }
            reject = nil
            if out {
                noticeKey += 1
                let key = noticeKey
                let name = room.player(playerId)?.name ?? "someone"
                outNotice = name
                after(2400) { session in if session.noticeKeyForOut == key { session.outNotice = nil } }
                noticeKeyForOut = key
            }
        case "category":
            if event.why != "start" { answerChips = [:] }
            if event.why == "cleared" {
                frozen = true
                categoryCleared = true
                card?.cleared = true
                after(Party.categorySwapMs - 420) { session in session.card?.leaving = true }
                after(Party.categorySwapMs) { session in session.unfreeze() }
            } else if event.why == "start" {
                frozen = false
            }
        case "win":
            noticeKey += 1
            let key = noticeKey
            let id = event.playerId
            after(1200, force: true) { session in session.winner = WinnerNotice(playerId: id, key: key) }
        case "lobby":
            frozen = false
            cardIndex = 0
            winner = nil
            outNotice = nil
            categoryCleared = false
            answerChips = [:]
        default:
            break
        }
    }

    @ObservationIgnored private var noticeKeyForOut = 0

    private func clearAnswerAfterPass() {
        revision += 1
        answer = ""
        typing.clear()
        telemetry.reset()
    }

    /// Haptics in place of the web's sound effects.
    private func playEffects(_ room: Room, _ fresh: [RoomEvent], isFirst: Bool) {
        let myId = seat?.playerId
        for event in fresh where room.now - event.at <= 1500 {
            switch event.kind {
            case "countdown": if room.phase == .countdown { Haptics.begin() }
            case "pass": if event.to == myId { Haptics.yourTurn() } else { Haptics.soft() }
            case "reject": if event.playerId == myId { Haptics.reject() }
            case "spare": Haptics.spare()
            case "pop": Haptics.pop(mine: event.playerId == myId)
            case "win": if event.playerId == myId { Haptics.win() }
            default: break
            }
        }
        let turnKey = room.phase == .round && room.holderId == myId && room.player(myId)?.alive == true
            ? "\(room.gameNumber):\(room.holderSince ?? 0)" : nil
        if let turnKey, turnKey != lastTurnKey, !isFirst,
           !fresh.contains(where: { $0.kind == "pass" && $0.to == myId }) {
            Haptics.yourTurn()
        }
        lastTurnKey = turnKey
    }

    /// Runs `action` after `ms` unless the session was torn down.
    private func after(_ ms: Int, force: Bool = false, _ action: @escaping (RoomSession) -> Void) {
        let id = UUID()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            self.timers[id] = nil
            action(self)
        }
    }

    // MARK: Derived UI state

    /// Current server time in ms.
    func serverNow(_ date: Date = Date()) -> Double {
        date.timeIntervalSince1970 * 1000 + clockOffset
    }

    /// Puffer swell 0...5 at `date`.
    func level(at date: Date = Date()) -> Int {
        guard let room, room.phase == .round, room.holderId != nil, let since = room.holderSince else { return 0 }
        return PufferLevel.level(heldSeconds: (serverNow(date) - since) / 1000, thresholds: thresholds)
    }

    func secondsUntil(_ serverMs: Double?, at date: Date = Date()) -> Int {
        guard let serverMs else { return 0 }
        return max(0, Int(((serverMs - serverNow(date)) / 1000).rounded(.up)))
    }

    var isHost: Bool { room?.hostId == seat?.playerId && seat != nil }

    /// Rated quick-play table.
    var isRatedTable: Bool { room?.table != nil && room?.rated == true }

    /// The line under the ring ("▸ … is up").
    var statusText: AttributedString? {
        guard let room else { return nil }
        let myId = seat?.playerId
        func bold(_ s: String) -> AttributedString {
            var a = AttributedString(s)
            a.inlinePresentationIntent = .stronglyEmphasized
            return a
        }
        let winnerPlayer = room.player(room.winnerId)
        if room.phase == .over {
            if let w = winnerPlayer {
                return bold(w.name) + AttributedString(w.id == myId ? " win the puffer" : " wins the puffer")
            }
            return AttributedString("the ring emptied")
        }
        if let outNotice { return bold(outNotice) + AttributedString(" is out") }
        if room.phase == .countdown { return AttributedString("the puffer is waking up") }
        if categoryCleared { return AttributedString("category cleared") }
        if room.phase == .round, let holder = room.player(room.holderId), !inputLocked {
            let core: AttributedString = holder.id == myId
                ? bold("your puffer") + AttributedString(" · type an answer")
                : bold(holder.name) + AttributedString(" is up")
            if card?.tag == "new" { return bold("new category") + AttributedString(" · ") + core }
            return core
        }
        return nil
    }

    /// Placeholder of the answer box.
    var answerPlaceholder: String {
        guard let room else { return "wait for the puffer…" }
        if isMyTurn { return "your puffer — type!" }
        if let me, !me.alive, room.phase == .round {
            if me.place == nil {
                return me.isReady ? "you're in next game · watching…" : "spectating this game…"
            }
            return "you're out · watching…"
        }
        if outNotice != nil || inputLocked { return "pop! hold on…" }
        if room.phase == .round, let holder = room.player(room.holderId) {
            return "\(holder.name.lowercased()) is up…"
        }
        return "wait for the puffer…"
    }

    /// Wait line in quick-play lobbies.
    func queueWaitText(at date: Date = Date()) -> String? {
        guard let room, let table = room.table else { return nil }
        let ready = room.players.filter { $0.isReady && $0.connected }.count
        if room.gatherEndsAt != nil {
            return "▸ starting in \(secondsUntil(room.gatherEndsAt, at: date))s · more can still join"
        }
        let missing = table.min - ready
        if missing <= 0 { return "▸ the puffer is waking up" }
        if table.max == 2 { return "▸ finding an opponent\(room.rated ? " near your rating" : "")…" }
        return "▸ waiting for \(missing) more \(missing == 1 ? "player" : "players")…"
    }

    // MARK: Chat

    var unreadChat: Int {
        guard let room, let myId = seat?.playerId else { return 0 }
        return room.chat.filter { $0.id > lastReadChatId && $0.playerId != nil && $0.playerId != myId
            && !muted.contains($0.playerId!) }.count
    }

    func markChatRead() {
        lastReadChatId = room?.chat.last?.id ?? lastReadChatId
    }

    func toggleMute(_ playerId: String) {
        if muted.contains(playerId) { muted.remove(playerId) } else { muted.insert(playerId) }
        PartyStorage.muted = muted
    }
}

/// Sends what the holder is typing at most every 220ms (40 chars max).
@MainActor
final class TypingThrottle {
    private let sendText: (String) async -> Void
    private var queued: String?
    private var timer: Task<Void, Never>?
    private var inFlight = false
    private var stopped = false
    private var lastSent = Date.distantPast
    private let interval: TimeInterval = 0.22

    init(_ send: @escaping (String) async -> Void) {
        sendText = send
    }

    func update(_ text: String) {
        queued = String(text.prefix(40))
        pump()
    }

    func clear() {
        queued = nil
        timer?.cancel()
        timer = nil
    }

    func stop() {
        stopped = true
        clear()
    }

    private func pump() {
        guard !stopped, !inFlight, timer == nil, queued != nil else { return }
        let wait = max(0, interval - Date().timeIntervalSince(lastSent))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.timer = nil
            guard let text = self.queued else { return }
            self.queued = nil
            self.lastSent = Date()
            self.inFlight = true
            await self.sendText(text)
            self.inFlight = false
            self.pump()
        }
    }
}
