import SwiftUI

/// State of the home screen ("the door"): identity, quick play, hosting,
/// joining by code and the public room list.
@MainActor
@Observable
final class DoorModel {
    struct Failure: Equatable {
        enum Retry: Equatable {
            case quick(rated: Bool)
            case host
            case join(code: String, section: Section)
        }

        let section: Section
        let message: String
        var seatedRoom: String?
        var retry: Retry?
    }

    enum Section: Equatable { case name, quick, host, code, list }

    var name = PartyStorage.name
    var character = PartyStorage.character
    var size = PartyStorage.quickPlaySize
    var isPrivate = false
    var codeInput = ""
    private(set) var busy: String?
    private(set) var failure: Failure?
    private(set) var rooms: [RoomSummary]?
    private(set) var roomsFailed = false
    private(set) var hasMoreRooms = false
    private(set) var loadingMore = false
    private(set) var pages = 1
    private(set) var rating: RatingInfo?
    private(set) var playing: Int?
    private(set) var pendingRatings = 0
    private(set) var settledRatings: [RatingRecent] = []
    private(set) var heldSeat: (code: String, seat: Seat)?

    /// Set when a seat was obtained; the view navigates to the room.
    @ObservationIgnored var onSeated: ((String, Seat) -> Void)?

    @ObservationIgnored private var roomsTask: Task<Void, Never>?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?

    var streak: Int { PartyStorage.maxStreak }

    func appear() {
        character = PartyStorage.character
        name = name.isEmpty ? PartyStorage.name : name
        heldSeat = PartyStorage.latestHeldSeat()
        PartyAPI.shared.warmIdentity()
        startPolling()
    }

    func disappear() {
        roomsTask?.cancel()
        pulseTask?.cancel()
    }

    func refresh() async {
        await loadRooms()
        await refreshRating()
        playing = await PartyAPI.shared.activity()
    }

    private func startPolling() {
        roomsTask?.cancel()
        roomsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadRooms()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick % 6 == 0 {
                    let count = await PartyAPI.shared.activity()
                    self?.playing = count
                }
                if tick % 6 == 0 || (self?.pendingRatings ?? 0) > 0 { await self?.refreshRating() }
                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func loadRooms() async {
        do {
            let result = try await PartyAPI.shared.listRoomPages(pages)
            rooms = result.rooms
            hasMoreRooms = result.nextCursor != nil
            roomsFailed = false
        } catch {
            roomsFailed = true
        }
        loadingMore = false
    }

    func loadMore() {
        loadingMore = true
        pages += 1
        Task { await loadRooms() }
    }

    private func refreshRating() async {
        let pending = PartyStorage.pendingRatings
        pendingRatings = pending.count
        guard let info = try? await PartyAPI.shared.myRating() else { return }
        rating = info
        let recent = Dictionary((info.rating?.recent ?? []).map { ($0.gameId, $0) }, uniquingKeysWith: { a, _ in a })
        let still = pending.filter { recent[$0.gameId] == nil }
        let settled = pending.compactMap { recent[$0.gameId] }
        PartyStorage.pendingRatings = still
        pendingRatings = still.count
        for s in settled where !settledRatings.contains(where: { $0.gameId == s.gameId }) {
            settledRatings.append(s)
        }
    }

    // MARK: Actions

    func setCharacter(_ id: String) {
        character = id
        PartyStorage.character = id
    }

    func setSize(_ id: String) {
        size = id
        PartyStorage.quickPlaySize = id
    }

    func clearNameError() {
        if failure?.section == .name { failure = nil }
    }

    private func validName() -> String? {
        guard let valid = Party.normalizeName(name) else {
            failure = Failure(section: .name, message: Party.nameHelp)
            return nil
        }
        return valid
    }

    private func fail(_ section: Section, _ error: Error, code: String? = nil, retry: Failure.Retry) {
        if let error = error as? PartyError {
            failure = Failure(section: section, message: error.displayText(code: code),
                              seatedRoom: error.seatedElsewhereRoom, retry: retry)
        } else {
            failure = Failure(section: section, message: "something went wrong", retry: retry)
        }
    }

    private func seated(_ code: String, _ grant: SeatGrant, name: String) {
        PartyStorage.name = name
        let seat = Seat(playerId: grant.playerId, playerKey: grant.playerKey, name: name, character: character)
        PartyStorage.saveSeat(code, seat)
        onSeated?(code, seat)
    }

    func quickPlay(rated: Bool, replace: Bool = false) {
        guard let name = validName(), busy == nil else { return }
        busy = rated ? "rated" : "quick"
        failure = nil
        Task {
            defer { busy = nil }
            do {
                let result = try await PartyAPI.shared.quickPlay(
                    name: name, character: character, size: size, rated: rated, replace: replace)
                guard case .seated(let grant) = result else {
                    throw PartyError(message: "no seat", status: 500)
                }
                seated(grant.code, grant, name: name)
            } catch {
                fail(.quick, error, retry: .quick(rated: rated))
            }
        }
    }

    func host(replace: Bool = false) {
        guard let name = validName(), busy == nil else { return }
        busy = "host"
        failure = nil
        Task {
            defer { busy = nil }
            do {
                let grant = try await PartyAPI.shared.createRoom(
                    name: name, character: character, isPrivate: isPrivate, replace: replace)
                seated(grant.code, grant, name: name)
            } catch {
                fail(.host, error, retry: .host)
            }
        }
    }

    func join(_ rawCode: String, from section: Section, replace: Bool = false) {
        guard let code = Party.normalizeCode(rawCode) else {
            failure = Failure(section: section, message: "room codes are 4 letters")
            return
        }
        if let seat = PartyStorage.loadSeat(code) {
            onSeated?(code, seat)
            return
        }
        guard let name = validName(), busy == nil else { return }
        busy = code
        failure = nil
        Task {
            defer { busy = nil }
            do {
                let grant = try await PartyAPI.shared.joinRoom(code: code, name: name, character: character, replace: replace)
                seated(code, grant, name: name)
            } catch {
                fail(section, error, code: code, retry: .join(code: code, section: section))
            }
        }
    }

    /// "LEAVE ROOM X AND CONTINUE".
    func retryReplacing() {
        guard let retry = failure?.retry else { return }
        switch retry {
        case .quick(let rated): quickPlay(rated: rated, replace: true)
        case .host: host(replace: true)
        case .join(let code, let section): join(code, from: section, replace: true)
        }
    }

    func forgetHeldSeat() {
        if let heldSeat { PartyStorage.clearSeat(heldSeat.code) }
        heldSeat = nil
    }
}

struct DoorView: View {
    @Bindable var model: DoorModel
    var openRoom: (String, Seat?) -> Void
    @State private var showHowTo = false
    @FocusState private var focus: Field?

    enum Field { case name, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if let held = model.heldSeat { rejoinBanner(held) }
                identityPanel
                quickPanel
                HStack(alignment: .top, spacing: 12) {
                    hostPanel
                    codePanel
                }
                roomsPanel
                Text("Party rooms, ratings and categories are shared with krillion.io/party.")
                    .font(.pixel(16))
                    .foregroundStyle(Palette.drift.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh() }
        .background(ReefBackground(dim: 0.45))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            model.onSeated = { code, seat in openRoom(code, seat) }
            model.appear()
            if !PartyStorage.howToPlaySeen {
                PartyStorage.howToPlaySeen = true
                showHowTo = true
            }
        }
        .onDisappear { model.disappear() }
        .sheet(isPresented: $showHowTo) { HowToPlayView() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
                    .font(.pixel(22))
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            PartyTitle()
                .padding(.top, 24)
            Text("Krillion's multiplayer category game. Name an answer and pass the puffer before it pops. Play with friends or join a public room. Last one floating wins.")
                .font(.pixel(20))
                .foregroundStyle(Palette.foam.opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PufferSprite(level: 0, sleeping: false, size: 72)
                .padding(.vertical, 4)
            if let playing = model.playing {
                HStack(spacing: 6) {
                    Circle().fill(playing > 0 ? Palette.ok : Palette.drift).frame(width: 8, height: 8)
                    Text("\(playing.formatted()) playing")
                        .font(.pixel(18))
                        .foregroundStyle(Palette.foam)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func rejoinBanner(_ held: (code: String, seat: Seat)) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("YOU'RE STILL SEATED").pixelLabel(16, color: Palette.cyan)
                Text("room \(held.code) as \(held.seat.name)")
                    .font(.pixel(20))
                    .foregroundStyle(Palette.foam)
            }
            Spacer()
            Button("REJOIN") { openRoom(held.code, nil) }
                .buttonStyle(QuietButtonStyle(color: Palette.cyan, fill: true))
            Button {
                model.forgetHeldSeat()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Forget seat in room \(held.code)")
        }
        .pixelPanel(padding: 12, border: Palette.cyan.opacity(0.6))
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WHO'S PLAYING").pixelLabel(20, color: Palette.foam)
                Spacer()
                Button("HOW TO PLAY") { showHowTo = true }
                    .font(.pixel(18))
                    .tracking(2)
                    .foregroundStyle(Palette.foam)
                    .underline()
            }
            IdentityFields(
                name: $model.name,
                character: model.character,
                streak: model.streak,
                onCharacter: { model.setCharacter($0) },
                onSubmit: { model.quickPlay(rated: false) },
                focus: $focus,
                focusValue: .name
            )
            .onChange(of: model.name) { _, _ in model.clearNameError() }
            failureView(.name)
        }
        .pixelPanel()
    }

    private var quickPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PLAY NOW").pixelLabel(20, color: Palette.foam)
                Spacer()
                if let rating = model.rating?.rating {
                    (Text("RATING ").foregroundStyle(Palette.drift) + Text(formatRating(rating.rating)).foregroundStyle(Palette.gold))
                        .font(.pixel(20))
                        .tracking(2)
                        .accessibilityLabel("Rating \(formatRating(rating.rating)), \(rating.games) rated games, \(rating.wins) wins, best \(formatRating(rating.peak))")
                }
            }
            if model.pendingRatings > 0 || !model.settledRatings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.settledRatings, id: \.gameId) { change in
                        HStack(spacing: 4) {
                            Text("Previous rated game:").foregroundStyle(Palette.foam)
                            Text(change.delta > 0 ? "+\(change.delta) Elo" : change.delta < 0 ? "\(change.delta) Elo" : "±0 Elo")
                                .foregroundStyle(change.delta > 0 ? Palette.ok : change.delta < 0 ? Palette.pink : Palette.drift)
                        }
                    }
                    if model.pendingRatings > 0 {
                        Text("Updating your rating… Your Elo change will appear here.")
                            .foregroundStyle(Palette.drift)
                    }
                }
                .font(.pixel(18))
            }
            Picker("Table size", selection: Binding(get: { model.size }, set: { model.setSize($0) })) {
                ForEach(QuickPlayTable.all, id: \.id) { table in
                    Text(table.label).tag(table.id)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.busy != nil)
            Text(QuickPlayTable.table(model.size)?.hint ?? "")
                .font(.pixel(17))
                .foregroundStyle(Palette.drift)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    Button(model.busy == "rated" ? "FINDING…" : "▶ RATED ◀") { model.quickPlay(rated: true) }
                        .buttonStyle(BeginButtonStyle(color: Palette.gold))
                        .disabled(model.busy != nil)
                    Text("near your rating · it moves").font(.pixel(16)).foregroundStyle(Palette.drift)
                }
                VStack(spacing: 6) {
                    Button(model.busy == "quick" ? "FINDING…" : "QUICK PLAY") { model.quickPlay(rated: false) }
                        .buttonStyle(BeginButtonStyle(color: Palette.pink))
                        .disabled(model.busy != nil)
                    Text("unrated · just for fun").font(.pixel(16)).foregroundStyle(Palette.drift)
                }
            }
            if let info = model.rating, info.rating != nil {
                Text(info.merged > 0
                     ? "\(info.merged) \(info.merged == 1 ? "game" : "games") from this device added to your account"
                     : info.account ? "your rating is saved to your account" : "your rating is saved on this device")
                    .font(.pixel(16))
                    .foregroundStyle(Palette.drift)
            }
            failureView(.quick)
        }
        .pixelPanel()
    }

    private var hostPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOST").pixelLabel(20, color: Palette.foam)
            Button(model.busy == "host" ? "OPENING…" : "▼ HOST ▼") { model.host() }
                .buttonStyle(BeginButtonStyle(color: Palette.cyan, height: 50))
                .disabled(model.busy != nil)
                .accessibilityLabel("Host a room")
            Button {
                model.isPrivate.toggle()
            } label: {
                Text(model.isPrivate ? "PRIVATE · CODE ONLY" : "PUBLIC · LISTED")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(color: model.isPrivate ? Palette.gold : Palette.cyan, size: 17))
            Text(model.isPrivate ? "friends join with the code" : "anyone can join from the list")
                .font(.pixel(16))
                .foregroundStyle(Palette.drift)
            failureView(.host)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(padding: 12)
    }

    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("JOIN BY CODE").pixelLabel(20, color: Palette.foam)
            CodeInput(code: $model.codeInput, focus: $focus, focusValue: .code) {
                model.join(model.codeInput, from: .code)
            }
            Button("JOIN") { model.join(model.codeInput, from: .code) }
                .buttonStyle(BeginButtonStyle(color: Palette.pink, height: 44))
                .disabled(model.codeInput.count != 4 || model.busy != nil)
            failureView(.code)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(padding: 12)
    }

    private var roomsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PUBLIC ROOMS").pixelLabel(20, color: Palette.foam)
                Spacer()
                if let rooms = model.rooms, !rooms.isEmpty {
                    Text("SHOWING \(rooms.count)").pixelLabel(16)
                }
            }
            if model.rooms == nil {
                Text(model.roomsFailed ? "can't reach the rooms right now" : "listening for rooms…")
                    .font(.pixel(19)).foregroundStyle(Palette.drift)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else if model.rooms?.isEmpty == true {
                Text("no open rooms right now. host one")
                    .font(.pixel(19)).foregroundStyle(Palette.drift)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            LazyVStack(spacing: 8) {
                ForEach(model.rooms ?? []) { room in
                    RoomRow(room: room, busy: model.busy == room.code) {
                        model.join(room.code, from: .list)
                    }
                    .disabled(room.isFull || model.busy != nil)
                }
            }
            if model.hasMoreRooms {
                Button(model.loadingMore ? "LOADING…" : "LOAD MORE") { model.loadMore() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.loadingMore)
                    .frame(maxWidth: .infinity)
            }
            if model.roomsFailed && model.rooms != nil {
                Text("Couldn't update the rooms. Retrying…").font(.pixel(17)).foregroundStyle(Palette.pink)
            }
            failureView(.list)
        }
        .pixelPanel()
    }

    @ViewBuilder
    private func failureView(_ section: DoorModel.Section) -> some View {
        if let failure = model.failure, failure.section == section {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.message)
                    .font(.pixel(18))
                    .foregroundStyle(Palette.pink)
                if let room = failure.seatedRoom {
                    Button("LEAVE ROOM \(room) AND CONTINUE") { model.retryReplacing() }
                        .buttonStyle(QuietButtonStyle(color: Palette.pink, size: 17))
                        .disabled(model.busy != nil)
                }
            }
            .transition(.opacity)
        }
    }
}

struct RoomRow: View {
    let room: RoomSummary
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(room.code)
                    .font(.pixel(26))
                    .foregroundStyle(Palette.cyan)
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(room.hostName)
                        .font(.pixel(20))
                        .foregroundStyle(Palette.foam)
                        .lineLimit(1)
                    Text("\(room.players)/\(room.maxPlayers) · \(room.phase == "lobby" ? "IN THE LOBBY" : "PLAYING")")
                        .font(.pixel(16))
                        .tracking(1)
                        .foregroundStyle(room.phase == "lobby" ? Palette.ok : Palette.drift)
                }
                Spacer()
                Text(busy ? "…" : room.isFull ? "FULL" : "JOIN ▸")
                    .font(.pixel(20))
                    .tracking(2)
                    .foregroundStyle(room.isFull ? Palette.drift : Palette.pink)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .background(NotchedRect(notch: 4).fill(Palette.abyss.opacity(0.55)))
            .overlay(NotchedRect(notch: 4).stroke(Palette.pfLine, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Room \(room.code), host \(room.hostName), \(room.players) of \(room.maxPlayers), \(room.phase == "lobby" ? "in the lobby" : "playing")")
        .accessibilityHint(room.isFull ? "Full" : "Join")
    }
}

/// Four big letter boxes for a room code.
struct CodeInput<F: Hashable>: View {
    @Binding var code: String
    var focus: FocusState<F?>.Binding
    let focusValue: F
    var onSubmit: () -> Void

    var body: some View {
        ZStack {
            TextField("", text: Binding(
                get: { code },
                set: { code = String($0.uppercased().filter { ("A"..."Z").contains($0) }.prefix(4)) }
            ))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.go)
            .focused(focus, equals: focusValue)
            .onSubmit(onSubmit)
            .foregroundStyle(.clear)
            .tint(.clear)
            .accessibilityLabel("Room code")

            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    let chars = Array(code)
                    Text(i < chars.count ? String(chars[i]) : "·")
                        .font(.pixel(30))
                        .foregroundStyle(i < chars.count ? Palette.foam : Palette.drift.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Palette.abyss.opacity(0.7))
                        .overlay(Rectangle().stroke(i == chars.count && focus.wrappedValue == focusValue ? Palette.cyan : Palette.pfLine, lineWidth: 2))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = focusValue }
    }
}
