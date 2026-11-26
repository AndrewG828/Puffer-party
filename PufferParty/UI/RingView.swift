import SwiftUI

/// The ring of perches with every player and the puffer moving between them.
/// You always sit at the bottom; the ring scales to whatever space is left
/// above the keyboard.
struct RingView: View {
    let session: RoomSession
    let room: Room

    private static let perches = [1, 6, 4, 8, 2, 5, 3, 7]

    private struct SeatSlot: Identifiable {
        let id: String
        let player: Player?
        let perch: Int
    }

    var body: some View {
        GeometryReader { geo in
            let slots = makeSlots()
            let n = max(1, slots.count)
            let unit = seatSize(count: n, in: geo.size)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rx = max(0, geo.size.width / 2 - unit * 0.85)
            let ry = max(0, geo.size.height / 2 - unit * 0.95)

            ZStack {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let point = position(index: index, count: n, center: center, rx: rx, ry: ry)
                    SeatView(session: session, room: room, player: slot.player, perch: slot.perch, unit: unit)
                        .position(point)
                }
                puffer(slots: slots, count: n, center: center, rx: rx, ry: ry, unit: unit)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: slots.map(\.id))
        }
    }

    private func makeSlots() -> [SeatSlot] {
        let myId = session.seat?.playerId
        var players: [Player]
        if room.phase == .lobby {
            players = room.players.filter { $0.isReady && $0.connected }
        } else {
            players = room.players.filter { $0.alive || $0.place != nil }
        }
        players.sort { $0.seat < $1.seat }
        if let mine = players.firstIndex(where: { $0.id == myId }), mine > 0 {
            players = Array(players[mine...] + players[..<mine])
        }
        var slots = players.map { SeatSlot(id: $0.id, player: $0, perch: Self.perches[$0.seat % Self.perches.count]) }
        if room.phase == .lobby {
            let open = max(0, room.settings.maxPlayers - room.players.filter { !$0.observer }.count)
            let used = Set(slots.map(\.perch))
            let free = Self.perches.filter { !used.contains($0) }
            for i in 0..<min(open, 16) {
                let perch = free.isEmpty ? Self.perches[(slots.count) % Self.perches.count] : free[i % free.count]
                slots.append(SeatSlot(id: "open:\(i)", player: nil, perch: perch))
            }
        }
        return slots
    }

    private func seatSize(count: Int, in size: CGSize) -> CGFloat {
        let short = min(size.width, size.height * 1.15)
        let divisor: CGFloat = count <= 2 ? 3.4 : count <= 4 ? 4.0 : count <= 6 ? 4.6 : count <= 10 ? 5.6 : 6.8
        return max(30, min(78, short / divisor))
    }

    /// Index 0 (you) at the bottom, the rest clockwise.
    private func position(index: Int, count: Int, center: CGPoint, rx: CGFloat, ry: CGFloat) -> CGPoint {
        let angle = Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
        return CGPoint(x: center.x + rx * CGFloat(cos(angle)), y: center.y + ry * CGFloat(sin(angle)))
    }

    @ViewBuilder
    private func puffer(slots: [SeatSlot], count: Int, center: CGPoint, rx: CGFloat, ry: CGFloat, unit: CGFloat) -> some View {
        let holderIndex = slots.firstIndex { $0.id == room.holderId }
        let winnerIndex = slots.firstIndex { $0.id == room.winnerId }
        let target: CGPoint = {
            if room.phase == .round, let holderIndex {
                let p = position(index: holderIndex, count: count, center: center, rx: rx, ry: ry)
                return CGPoint(x: p.x + (center.x - p.x) * 0.42, y: p.y + (center.y - p.y) * 0.42 - unit * 0.2)
            }
            if room.phase == .over, let winnerIndex {
                let p = position(index: winnerIndex, count: count, center: center, rx: rx, ry: ry)
                return CGPoint(x: p.x, y: p.y - unit * 1.1)
            }
            return center
        }()
        let sleeping = room.phase != .round || room.holderId == nil

        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let level = session.level(at: context.date)
            ZStack {
                PufferSprite(level: level, sleeping: sleeping, size: unit * 1.45)
                    .shadow(color: level >= 4 ? Palette.pink.opacity(0.7) : .clear, radius: level >= 4 ? 14 : 0)
                    .modifier(Shake(amount: level >= 5 ? 3 : level >= 4 ? 1.5 : 0, phase: context.date.timeIntervalSinceReferenceDate))
                if let key = session.popKeys.values.max() {
                    PopBurst(key: key).id(key)
                }
            }
        }
        .position(target)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: target.x)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: target.y)
        .allowsHitTesting(false)
    }
}

/// Jitter used when the puffer is about to blow.
struct Shake: GeometryEffect {
    var amount: CGFloat
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard amount > 0 else { return ProjectionTransform(.identity) }
        let x = amount * CGFloat(sin(phase * 47))
        let y = amount * CGFloat(cos(phase * 39))
        return ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }
}

/// One perch: speech bubble, buddy, name plate, hearts and meter.
struct SeatView: View {
    let session: RoomSession
    let room: Room
    let player: Player?
    let perch: Int
    let unit: CGFloat

    @State private var popFlash = false
    @State private var spareFloat = false

    var body: some View {
        VStack(spacing: 1) {
            bubble
                .frame(height: unit * 0.42)
            ZStack(alignment: .bottom) {
                Image("perch-\(perch)")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: unit * 1.25)
                    .shadow(color: isHolder ? Palette.pink.opacity(0.8) : .clear, radius: isHolder ? 10 : 0)
                if let player {
                    Image(isWinner ? Buddy.find(player.character).goldSprite : Buddy.find(player.character).sprite)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: unit * 0.9, height: unit * 0.9)
                        .offset(y: -unit * 0.42)
                        .colorMultiply(popFlash ? Palette.danger : .white)
                        .saturation(isOut ? 0 : 1)
                        .opacity(isOut ? 0.45 : (player.connected ? 1 : 0.5))
                } else {
                    Text("OPEN")
                        .font(.pixel(max(13, unit * 0.22)))
                        .tracking(2)
                        .foregroundStyle(Palette.drift.opacity(0.7))
                        .offset(y: -unit * 0.4)
                }
                if spareFloat {
                    HStack(spacing: 2) {
                        Text("+")
                        PixelHeart(size: 12)
                    }
                    .font(.pixel(20))
                    .foregroundStyle(Palette.pink)
                    .offset(y: -unit * 1.2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(height: unit * 1.05)
            plate
        }
        .frame(width: unit * 1.9)
        .onChange(of: player.flatMap { session.popKeys[$0.id] }) { _, key in
            guard key != nil else { return }
            withAnimation(.easeOut(duration: 0.12)) { popFlash = true }
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.easeIn(duration: 0.3)) { popFlash = false }
            }
        }
        .onChange(of: player.flatMap { session.spareKeys[$0.id] }) { _, key in
            guard key != nil else { return }
            withAnimation(.spring) { spareFloat = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut) { spareFloat = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isMe: Bool { player != nil && player?.id == session.seat?.playerId }
    private var isHolder: Bool { room.phase == .round && player != nil && player?.id == room.holderId }
    private var isWinner: Bool { room.phase == .over && player != nil && player?.id == room.winnerId }
    private var isOut: Bool { room.phase != .lobby && player?.alive == false }

    @ViewBuilder
    private var bubble: some View {
        if let player {
            let hideFree = session.muted.contains(player.id) || player.chatMuted || !room.chatEnabled
            if isHolder, !hideFree {
                let typed = player.id == session.seat?.playerId ? session.answer : (player.typing ?? "")
                BubbleText(text: typed.isEmpty ? "…" : typed, color: Palette.foam, border: Palette.pink, unit: unit, cursor: true)
            } else if let rejected = session.rejectChips[player.id], !hideFree {
                BubbleText(text: rejected, color: Palette.drift, border: Palette.danger, unit: unit, strike: true)
            } else if let chip = session.answerChips[player.id] {
                BubbleText(text: chip.text, color: Palette.tier(chip.tier), border: Palette.tier(chip.tier).opacity(0.7),
                           unit: unit, tierLabel: Tier.find(chip.tier)?.label)
            } else {
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    private var plate: some View {
        VStack(spacing: 1) {
            if let player {
                Text(isMe ? "YOU" : player.name.uppercased())
                    .font(.pixel(max(14, unit * 0.27)))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(isMe ? Palette.pink : (isHolder ? Palette.gold : Palette.foam))
                HStack(spacing: 2) {
                    if room.phase == .lobby || player.alive || player.place == nil {
                        ForEach(0..<max(0, min(player.lives, 10)), id: \.self) { _ in
                            PixelHeart(color: Palette.pink, size: max(8, unit * 0.15))
                        }
                    }
                    if let place = player.place, room.phase != .lobby, !player.alive {
                        Text("#\(place)").font(.pixel(max(13, unit * 0.22))).foregroundStyle(Palette.drift)
                    }
                    if let rating = player.rating {
                        Text(formatRating(rating))
                            .font(.pixel(max(12, unit * 0.2)))
                            .foregroundStyle(Palette.gold.opacity(0.9))
                        if let delta = player.ratingDelta, room.phase == .over {
                            Text(delta > 0 ? "+\(delta)" : delta < 0 ? "\(delta)" : "±0")
                                .font(.pixel(max(12, unit * 0.2)))
                                .foregroundStyle(delta > 0 ? Palette.ok : delta < 0 ? Palette.pink : Palette.drift)
                        }
                    }
                }
                if room.phase != .lobby {
                    SeatMeter(segments: session.segments[player.id] ?? [], target: room.settings.meterTarget)
                        .frame(width: unit * 0.9, height: max(3, unit * 0.06))
                }
                if !player.connected {
                    Text("away").font(.pixel(13)).foregroundStyle(Palette.drift)
                }
            }
        }
    }

    private var accessibilityText: String {
        guard let player else { return "Open seat" }
        var parts = [isMe ? "You" : player.name, "\(player.lives) \(player.lives == 1 ? "heart" : "hearts")"]
        if isHolder { parts.append("holding the puffer") }
        if isOut { parts.append(player.place.map { "out, place \($0)" } ?? "out") }
        if let chip = session.answerChips[player.id] { parts.append("answered \(chip.text)") }
        return parts.joined(separator: ", ")
    }
}

struct BubbleText: View {
    let text: String
    let color: Color
    let border: Color
    let unit: CGFloat
    var cursor = false
    var strike = false
    var tierLabel: String?
    @State private var blink = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(text)
                    .strikethrough(strike, color: Palette.danger)
                if cursor {
                    Text("▌").opacity(blink ? 0 : 1)
                }
            }
            .font(.pixel(max(15, unit * 0.3)))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.head)
            if let tierLabel {
                Text(tierLabel)
                    .font(.pixel(max(10, unit * 0.16)))
                    .tracking(1)
                    .foregroundStyle(color.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: unit * 2.6)
        .background(NotchedRect(notch: 3).fill(Palette.abyss.opacity(0.9)))
        .overlay(NotchedRect(notch: 3).stroke(border, lineWidth: 1.5))
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard cursor else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { blink = true }
        }
    }
}

/// Thin heart meter under a seat.
struct SeatMeter: View {
    let segments: [MeterSegment]
    let target: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(Palette.tier(segment.tier))
                        .frame(width: geo.size.width * CGFloat(segment.amount) / CGFloat(max(1, target)))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.meterEmpty)
        }
        .accessibilityHidden(true)
    }
}
