import SwiftUI

/// A live room: lobby, countdown, rounds and the end screen.
struct GameView: View {
    let session: RoomSession
    @State private var showChat = false
    @State private var confirmLeave = false
    @State private var showHowTo = false
    @State private var focusKey = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ReefBackground(dim: 0.3)
            if let room = session.room {
                content(room)
            } else {
                LoadingPill(text: session.stream == .reconnecting ? "reconnecting…" : "swimming in…", large: true)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showChat, onDismiss: { session.markChatRead() }) {
            ChatView(session: session)
        }
        .sheet(isPresented: $showHowTo) { HowToPlayView() }
        .alert("LEAVE THE GAME?", isPresented: $confirmLeave) {
            Button("KEEP PLAYING", role: .cancel) {}
            Button("LEAVE", role: .destructive) { session.leave() }
        } message: {
            Text("You're still floating. Leaving gives up your seat in this game, and you can't come back into it."
                 + (session.isRatedTable && session.room?.phase == .round ? " This is a rated game—leaving can cost you Elo." : ""))
        }
        .onChange(of: session.myTurnKey) { _, _ in focusKey += 1 }
        .onChange(of: session.room?.phase) { _, phase in
            if phase == .round, session.me?.alive == true { focusKey += 1 }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.resumed() }
        }
    }

    @ViewBuilder
    private func content(_ room: Room) -> some View {
        VStack(spacing: 0) {
            HUDBar(session: session, room: room,
                   onLeave: { requestLeave(room) },
                   onChat: { session.markChatRead(); showChat = true },
                   onHowTo: { showHowTo = true })
            if room.phase == .lobby {
                LobbyView(session: session, room: room, onHowTo: { showHowTo = true })
            } else {
                CategoryCardView(card: session.card, room: room)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                RingView(session: session, room: room)
                    .padding(.horizontal, 4)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .center) { overlays(room) }
                StatusLine(text: session.statusText, hidden: session.reject != nil)
                if room.phase == .over, session.winner != nil {
                    EndPanel(session: session, room: room)
                } else {
                    DockView(session: session, room: room, focusKey: focusKey)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let reject = session.reject {
                Text(reject.message)
                    .font(.pixel(22))
                    .foregroundStyle(Palette.foam)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(NotchedRect(notch: 4).fill(Palette.danger.opacity(0.9)))
                    .padding(.bottom, 96)
                    .modifier(ShakeOnAppear())
                    .id(reject.key)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .overlay(alignment: .top) {
            if session.stream == .reconnecting {
                LoadingPill(text: "reconnecting…", large: false)
                    .padding(.top, 110)
            }
        }
    }

    @ViewBuilder
    private func overlays(_ room: Room) -> some View {
        if room.phase == .countdown {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let seconds = session.secondsUntil(room.countdownEndsAt, at: context.date)
                if seconds > 0 {
                    VStack(spacing: 4) {
                        Text("\(seconds)")
                            .font(.pixel(120))
                            .foregroundStyle(Palette.foam)
                            .shadow(color: Palette.pink, radius: 0, x: -3, y: 2)
                            .shadow(color: Palette.cyan, radius: 0, x: 3, y: -2)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.spring, value: seconds)
                        Text("pass the puffer · don't let it pop on you")
                            .font(.pixel(20))
                            .foregroundStyle(Palette.foam)
                    }
                    .padding(20)
                    .background(Palette.abyss.opacity(0.6))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if room.phase == .over, let winner = session.winner {
            WinnerBanner(room: room, winnerId: winner.playerId, myId: session.seat?.playerId)
                .id(winner.key)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func requestLeave(_ room: Room) {
        let inPlay = (room.phase == .round || room.phase == .countdown) && session.me?.alive == true
        if inPlay { confirmLeave = true } else { session.leave() }
    }
}

// MARK: - HUD

struct HUDBar: View {
    let session: RoomSession
    let room: Room
    var onLeave: () -> Void
    var onChat: () -> Void
    var onHowTo: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                roomPod
                Spacer(minLength: 4)
                Text(midLabel)
                    .pixelLabel(18, color: Palette.foam.opacity(0.75), tracking: 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(room.phase == .lobby ? "READY" : "FLOATING").pixelLabel(14, tracking: 3)
                    Text(floatingText)
                        .font(.pixel(28))
                        .foregroundStyle(Palette.pink)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(NotchedRect(notch: 5).fill(Palette.panelSolid.opacity(0.9)))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Button(action: onLeave) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Leave room")
                Button(action: onHowTo) {
                    Image(systemName: "questionmark")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("How to play")
                Spacer()
                Button(action: onChat) {
                    Image(systemName: "bubble.left.fill")
                        .overlay(alignment: .topTrailing) {
                            if session.unreadChat > 0 {
                                Text(session.unreadChat > 9 ? "9+" : "\(session.unreadChat)")
                                    .font(.pixel(15))
                                    .foregroundStyle(Palette.abyss)
                                    .padding(.horizontal, 4)
                                    .background(Palette.pink)
                                    .offset(x: 14, y: -14)
                            }
                        }
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(session.unreadChat > 0 ? "Open chat, \(session.unreadChat) new" : "Open chat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var midLabel: String {
        switch room.phase {
        case .lobby: return room.gameNumber > 1 ? "GAME \(room.gameNumber) · LOBBY" : "LOBBY"
        case .countdown: return "GET READY"
        case .over: return "GAME OVER"
        case .round: return "CATEGORY \(room.category?.index ?? 1)"
        }
    }

    private var floatingText: String {
        if room.phase == .lobby {
            let ready = room.players.filter { $0.isReady && $0.connected }.count
            return "\(ready)/\(room.settings.maxPlayers)"
        }
        let alive = room.players.filter(\.alive).count
        let inGame = room.players.filter { $0.alive || $0.place != nil }.count
        return "\(alive)/\(inGame)"
    }

    @ViewBuilder
    private var roomPod: some View {
        let label: String = {
            if let table = room.table { return "\(room.rated ? "RATED" : "UNRATED") \(table.label)" }
            return room.settings.isPrivate ? "PRIVATE" : "PUBLIC"
        }()
        let pod = VStack(alignment: .leading, spacing: 0) {
            Text(label + (room.table == nil && session.isHost ? " ↔" : "")).pixelLabel(14, tracking: 3)
            Text(room.code)
                .font(.pixel(30))
                .foregroundStyle(Palette.cyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(NotchedRect(notch: 5).fill(Palette.panelSolid.opacity(0.9)))

        if room.table == nil && session.isHost {
            Button {
                session.updateSettings(["isPrivate": !room.settings.isPrivate])
            } label: { pod }
            .buttonStyle(.plain)
            .accessibilityLabel("Room \(room.code): \(label.lowercased()). \(room.settings.isPrivate ? "Make room public" : "Make room private")")
        } else {
            pod
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Room \(room.code), \(label.lowercased())")
        }
    }
}

// MARK: - Category card

struct CategoryCardView: View {
    let card: CategoryCard?
    let room: Room

    var body: some View {
        ZStack {
            if let card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CATEGORY \(card.index)").pixelLabel(17, color: Palette.pink, tracking: 4)
                        Spacer()
                        if card.cleared {
                            Chip(text: "CLEARED", color: Palette.ok)
                        } else if card.tag == "new" {
                            Chip(text: "NEW", color: Palette.gold)
                        }
                    }
                    Text(card.text)
                        .font(.pixel(card.text.count > 34 ? 26 : 32, relativeTo: .title))
                        .foregroundStyle(Palette.foam)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("▼ any answer passes the puffer ▼")
                        .font(.pixel(15))
                        .foregroundStyle(Palette.drift)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixelPanel(padding: 12, border: card.tag == "new" ? Palette.gold.opacity(0.7) : Palette.pfLine)
                .opacity(card.leaving ? 0 : (card.cleared ? 0.6 : 1))
                .offset(y: card.leaving ? -20 : 0)
                .id(card.index)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Category \(card.index): \(card.text)")
            } else if room.phase == .round {
                VStack(spacing: 2) {
                    Text("New category").font(.pixel(28)).foregroundStyle(Palette.foam)
                    Text("▼ here it comes ▼").font(.pixel(16)).foregroundStyle(Palette.drift)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .pixelPanel(padding: 12)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: card)
    }
}

struct StatusLine: View {
    let text: AttributedString?
    var hidden = false

    var body: some View {
        Group {
            if let text, !hidden {
                (Text("▸ ") + Text(text))
                    .font(.pixel(21))
                    .tracking(1.5)
                    .foregroundStyle(Palette.foam.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(" ").font(.pixel(21))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Dock

/// Bottom dock: heart meter, answer box with fuse, SEND.
struct DockView: View {
    let session: RoomSession
    let room: Room
    let focusKey: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let level = session.level(at: context.date)
            let hot = session.isMyTurn && level >= 5
            HStack(alignment: .center, spacing: 10) {
                HeartMeterRing(segments: session.segments[session.seat?.playerId ?? ""] ?? [],
                               target: room.settings.meterTarget,
                               lives: session.me?.lives ?? 0,
                               hot: hot)
                VStack(spacing: 4) {
                    AnswerField(
                        text: session.answer,
                        placeholder: session.answerPlaceholder,
                        enabled: session.canType,
                        focusKey: focusKey,
                        hot: session.isMyTurn,
                        onEdit: { session.answerEdited(newText: $0, inserted: $1, removedLength: $2) },
                        onSubmit: { session.submit() }
                    )
                    .frame(height: 48)
                    .padding(.horizontal, 10)
                    .background(Palette.abyss.opacity(0.85))
                    .overlay(Rectangle().stroke(session.isMyTurn ? (hot ? Palette.pink : Palette.cyan) : Palette.pfLine,
                                                lineWidth: session.isMyTurn ? 3 : 2))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(level >= 4 ? Palette.pink : Palette.cyan)
                            .frame(width: geo.size.width * CGFloat(room.phase == .round ? Double(level) / 5 : 0))
                            .animation(.easeOut(duration: 0.25), value: level)
                    }
                    .frame(height: 5)
                    .background(Palette.meterEmpty)
                    .accessibilityHidden(true)
                }
                Button(action: { session.submit() }) {
                    Text(session.sending ? "…" : "SEND")
                        .frame(width: 70)
                }
                .buttonStyle(BeginButtonStyle(color: Palette.pink, height: 56))
                .frame(width: 86)
                .disabled(!session.isMyTurn || session.sending || session.answer.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send answer")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(colors: [Palette.abyss.opacity(0), Palette.abyss.opacity(hot ? 0.95 : 0.85)],
                               startPoint: .top, endPoint: .center)
                    .overlay(hot ? Palette.pink.opacity(0.12) : .clear)
            )
            .modifier(Shake(amount: hot ? 1.5 : 0, phase: context.date.timeIntervalSinceReferenceDate))
            .onChange(of: level) { old, new in
                if session.isMyTurn && new > old { Haptics.tick(level: new) }
            }
        }
    }
}

// MARK: - End of game

struct WinnerBanner: View {
    let room: Room
    let winnerId: String?
    let myId: String?

    var body: some View {
        let winner = room.player(winnerId)
        VStack(spacing: 6) {
            if let winner {
                Image(Buddy.find(winner.character).goldSprite)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            Text(winner?.id == myId && winner != nil ? "YOU WIN" : (winner?.name.uppercased() ?? "ROUND OVER"))
                .font(.pixel(48))
                .foregroundStyle(Palette.gold)
                .shadow(color: Palette.abyss, radius: 0, x: 2, y: 2)
            Text(winner?.id == myId && winner != nil ? "last one floating" : winner != nil ? "wins the round" : "the ring is empty")
                .font(.pixel(22))
                .foregroundStyle(Palette.foam)
        }
        .padding(24)
        .background(NotchedRect(notch: 8).fill(Palette.abyss.opacity(0.8)))
        .accessibilityElement(children: .combine)
    }
}

struct EndPanel: View {
    let session: RoomSession
    let room: Room
    @State private var feedback: Int?
    @State private var notes = ""
    @State private var feedbackState = ""

    var body: some View {
        VStack(spacing: 10) {
            if let me = session.me, let rating = me.rating, let delta = me.ratingDelta {
                HStack(spacing: 6) {
                    Text("RATING").pixelLabel(18)
                    Text(formatRating(rating)).font(.pixel(24)).foregroundStyle(Palette.gold)
                    Text(delta > 0 ? "+\(delta)" : delta < 0 ? "\(delta)" : "±0")
                        .font(.pixel(24))
                        .foregroundStyle(delta > 0 ? Palette.ok : delta < 0 ? Palette.pink : Palette.drift)
                }
            }
            if let gameId = room.gameId, session.me?.place != nil {
                feedbackRow(gameId)
            }
            HStack(spacing: 10) {
                Button(room.table?.max == 2 ? "REMATCH" : "PLAY AGAIN") { session.playAgain() }
                    .buttonStyle(BeginButtonStyle(color: Palette.pink))
                if room.table != nil {
                    Button(room.table?.max == 2 ? "NEW OPPONENT" : "NEW TABLE") { session.findGame() }
                        .buttonStyle(BeginButtonStyle(color: Palette.cyan))
                }
            }
            AutoJoinToggle(session: session)
            if let error = session.joinError {
                Text(error).font(.pixel(17)).foregroundStyle(Palette.pink)
            }
        }
        .padding(12)
        .background(Palette.abyss.opacity(0.85))
    }

    @ViewBuilder
    private func feedbackRow(_ gameId: String) -> some View {
        VStack(spacing: 4) {
            if feedbackState == "done" {
                Text("logged — thanks for the note.").font(.pixel(17)).foregroundStyle(Palette.drift)
            } else {
                Text("how was that round?").font(.pixel(18)).foregroundStyle(Palette.foam)
                HStack(spacing: 6) {
                    Text("meh").font(.pixel(14)).foregroundStyle(Palette.drift)
                    ForEach(1...5, id: \.self) { value in
                        Button("\(value)") {
                            feedback = value
                            Task {
                                let ok = await PartyAPI.shared.sendFeedback(gameId: gameId, rating: value, notes: nil)
                                feedbackState = ok ? "rated" : "failed"
                            }
                        }
                        .buttonStyle(QuietButtonStyle(color: feedback == value ? Palette.gold : Palette.cyan, size: 18,
                                                      fill: feedback == value))
                        .accessibilityLabel("Rate \(value) of 5")
                    }
                    Text("great").font(.pixel(14)).foregroundStyle(Palette.drift)
                }
                if let feedback, feedbackState == "rated" {
                    HStack {
                        TextField("", text: $notes, prompt: Text("anything we should improve?").foregroundStyle(Palette.drift))
                            .font(.pixel(18))
                            .foregroundStyle(Palette.foam)
                            .padding(.horizontal, 8)
                            .frame(height: 36)
                            .background(Palette.abyss)
                            .overlay(Rectangle().stroke(Palette.pfLine, lineWidth: 1))
                        Button("submit") {
                            Task {
                                let ok = await PartyAPI.shared.sendFeedback(gameId: gameId, rating: feedback, notes: notes)
                                feedbackState = ok ? "done" : "failed"
                            }
                        }
                        .buttonStyle(QuietButtonStyle(size: 18))
                        .disabled(notes.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if feedbackState == "failed" {
                    Text("couldn't send — try again in a moment.").font(.pixel(15)).foregroundStyle(Palette.pink)
                }
            }
        }
    }
}

struct AutoJoinToggle: View {
    let session: RoomSession

    var body: some View {
        Toggle(isOn: Binding(get: { session.me?.autoJoin ?? false }, set: { session.setAutoJoin($0) })) {
            Text("AUTO-JOIN").pixelLabel(18, color: Palette.foam)
        }
        .toggleStyle(.switch)
        .tint(Palette.cyan)
        .fixedSize()
        .accessibilityHint("Automatically join the next game")
    }
}

struct LoadingPill: View {
    let text: String
    var large = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(Palette.cyan)
            Text(text).font(.pixel(large ? 26 : 18)).foregroundStyle(Palette.foam)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NotchedRect(notch: 4).fill(Palette.panelSolid.opacity(0.92)))
    }
}

struct ShakeOnAppear: ViewModifier {
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeX(phase: phase))
            .onAppear {
                withAnimation(.linear(duration: 0.4)) { phase = 1 }
            }
    }

    private struct ShakeX: GeometryEffect {
        var phase: Double
        var animatableData: Double {
            get { phase }
            set { phase = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            let x = 8 * sin(phase * .pi * 6) * (1 - phase)
            return ProjectionTransform(CGAffineTransform(translationX: CGFloat(x), y: 0))
        }
    }
}
