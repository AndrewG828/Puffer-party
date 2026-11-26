import SwiftUI
import UIKit

/// Room lobby: ring of ready players, room code + invite, settings and the
/// start button.
struct LobbyView: View {
    let session: RoomSession
    let room: Room
    var onHowTo: () -> Void
    @State private var showSettings = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            PartyTitle(compact: true)
                .padding(.top, 4)
            RingView(session: session, room: room)
                .frame(maxHeight: .infinity)
            footer
        }
        .sheet(isPresented: $showSettings) {
            RoomSettingsView(session: session)
        }
    }

    private var ready: [Player] { room.players.filter { $0.isReady && $0.connected } }

    private var footer: some View {
        VStack(spacing: 10) {
            if room.table == nil {
                codeRow
            }
            if let table = room.table {
                queueInfo(table)
            } else {
                HStack(spacing: 8) {
                    SettingTile(label: "LIVES", value: "\(room.settings.lives)")
                    SettingTile(label: "MIN. TURN", value: "\(room.settings.minTurnMs / 1000)s")
                    SettingTile(label: "SEATS", value: "\(room.settings.maxPlayers)")
                    Button {
                        showSettings = true
                    } label: {
                        VStack(spacing: 0) {
                            Text("RULES").pixelLabel(14, tracking: 2)
                            Text(session.isHost ? "EDIT" : "VIEW").font(.pixel(22)).foregroundStyle(Palette.cyan)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.abyss.opacity(0.6))
                        .overlay(Rectangle().stroke(Palette.cyan.opacity(0.6), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.isHost ? "Edit room settings" : "View room settings")
                }
            }
            primaryAction
            HStack(spacing: 10) {
                Text(seatsLine).pixelLabel(16, tracking: 2)
                Spacer()
                AutoJoinToggle(session: session)
            }
            HStack(spacing: 8) {
                Button("HOW TO PLAY", action: onHowTo)
                    .buttonStyle(QuietButtonStyle(color: Palette.foam, size: 17))
                if !session.isRatedTable {
                    ShareLink(item: Party.inviteURL(room.code),
                              subject: Text("Puffer Party"),
                              message: Text("Join my Puffer Party room \(room.code)")) {
                        Text("INVITE")
                    }
                    .buttonStyle(QuietButtonStyle(color: Palette.pink, size: 17))
                }
            }
        }
        .pixelPanel(padding: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var codeRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ROOM CODE").pixelLabel(14)
                Text(room.code)
                    .font(.pixel(40))
                    .tracking(6)
                    .foregroundStyle(Palette.cyan)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                UIPasteboard.general.url = Party.inviteURL(room.code)
                Haptics.tap()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Text(copied ? "link copied" : "krillion.io/party/\(room.code)")
                    .font(.pixel(17))
                    .foregroundStyle(Palette.drift)
                    .underline()
            }
            .accessibilityLabel("Copy invite link")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func queueInfo(_ table: QuickPlayTable) -> some View {
        HStack(spacing: 8) {
            SettingTile(label: room.rated ? "RATED TABLE" : "QUICK PLAY", value: table.label)
            if room.rated {
                SettingTile(label: "YOUR RATING", value: session.me?.rating.map(formatRating) ?? "—")
            } else {
                SettingTile(label: "RATING", value: "OFF")
            }
            SettingTile(label: "LIVES", value: "\(room.settings.lives)")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        let meReady = session.me?.isReady ?? true
        if meReady || (session.me?.observer == true && session.isHost) {
            if room.table != nil {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text(session.queueWaitText(at: context.date) ?? "")
                        .font(.pixel(22))
                        .foregroundStyle(Palette.foam)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
            } else if session.isHost {
                Button("▼ WAKE THE PUFFER ▼") { session.startGame() }
                    .buttonStyle(BeginButtonStyle(color: Palette.pink))
                    .disabled(ready.count < Party.minPlayersToStart)
                if ready.count < Party.minPlayersToStart {
                    Text("invite a friend: you need \(Party.minPlayersToStart) players")
                        .font(.pixel(16))
                        .foregroundStyle(Palette.drift)
                }
            } else {
                let hostName = room.player(room.hostId)?.name ?? "the host"
                (Text("▸ waiting for ") + Text(hostName).foregroundStyle(Palette.gold) + Text(" to wake the puffer"))
                    .font(.pixel(22))
                    .foregroundStyle(Palette.foam)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
        } else {
            Button("JOIN NEXT GAME") { session.playAgain() }
                .buttonStyle(BeginButtonStyle(color: Palette.pink))
        }
    }

    private var seatsLine: String {
        let all = room.players
        let watching = all.count - ready.count
        let open = max(0, room.settings.maxPlayers - all.filter { !$0.observer }.count)
        if watching > 0 { return "\(ready.count) READY · \(watching) WATCHING" }
        return open > 0 ? "\(ready.count) READY · \(open) OPEN" : "\(ready.count) READY · FULL"
    }
}

struct SettingTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label).pixelLabel(13, tracking: 1.5).lineLimit(1).minimumScaleFactor(0.6)
            Text(value).font(.pixel(24)).foregroundStyle(Palette.foam)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Palette.abyss.opacity(0.6))
        .overlay(Rectangle().stroke(Palette.pfLine, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// "ROOM SETTINGS": the host edits lives, turn time, seats and heart rules.
struct RoomSettingsView: View {
    let session: RoomSession
    @Environment(\.dismiss) private var dismiss

    private struct Setting: Identifiable {
        let id: String
        let label: String
        let value: Int
        let min: Int
        let max: Int
        var step = 1
        let format: (Int) -> String
        let patch: (Int) -> [String: Any]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ROOM SETTINGS").pixelLabel(26, color: Palette.foam)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Close settings")
            }
            if let room = session.room {
                ForEach(settings(room).prefix(3)) { row($0) }
                Text("HEART RULES").pixelLabel(18, color: Palette.cyan)
                ForEach(settings(room).dropFirst(3)) { row($0) }
                HStack {
                    Text("ROOM").pixelLabel(18)
                    Spacer()
                    Button(room.settings.isPrivate ? "PRIVATE · CODE ONLY" : "PUBLIC · LISTED") {
                        session.updateSettings(["isPrivate": !room.settings.isPrivate])
                    }
                    .buttonStyle(QuietButtonStyle(color: room.settings.isPrivate ? Palette.gold : Palette.cyan, size: 18))
                    .disabled(!session.isHost)
                }
                if !session.isHost {
                    Text("Only the host can change these.")
                        .font(.pixel(17))
                        .foregroundStyle(Palette.drift)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(Palette.panelSolid.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func settings(_ room: Room) -> [Setting] {
        let s = room.settings
        let seated = room.players.filter { !$0.observer }.count
        return [
            Setting(id: "lives", label: "LIVES", value: s.lives, min: 1, max: s.maxLives,
                    format: { "\($0)" }, patch: { ["lives": $0] }),
            Setting(id: "turn", label: "MIN. TURN", value: s.minTurnMs / 1000, min: 3, max: 15,
                    format: { "\($0)s" }, patch: { ["minTurnMs": $0 * 1000] }),
            Setting(id: "seats", label: "SEATS", value: s.maxPlayers, min: max(Party.minPlayersToStart, seated),
                    max: Party.maxPlayers, format: { "\($0)" }, patch: { ["maxPlayers": $0] }),
            Setting(id: "maxLives", label: "HEART CAP", value: s.maxLives, min: 1, max: Party.maxLives,
                    format: { "\($0)" }, patch: { ["maxLives": $0] }),
            Setting(id: "meterTarget", label: "POINTS / HEART", value: s.meterTarget, min: Party.meterTargetStep,
                    max: Party.maxMeterTarget, step: Party.meterTargetStep, format: { "\($0)" },
                    patch: { ["meterTarget": $0] }),
        ]
    }

    private func row(_ setting: Setting) -> some View {
        HStack {
            Text(setting.label).pixelLabel(18)
            Spacer()
            if session.isHost {
                Button("◀") {
                    Haptics.tap()
                    session.updateSettings(setting.patch(max(setting.min, setting.value - setting.step)))
                }
                .buttonStyle(QuietButtonStyle(size: 20))
                .disabled(setting.value <= setting.min)
                .accessibilityLabel("fewer \(setting.label.lowercased())")
            }
            Text(setting.format(setting.value))
                .font(.pixel(28))
                .foregroundStyle(Palette.foam)
                .frame(minWidth: 64)
            if session.isHost {
                Button("▶") {
                    Haptics.tap()
                    session.updateSettings(setting.patch(min(setting.max, setting.value + setting.step)))
                }
                .buttonStyle(QuietButtonStyle(size: 20))
                .disabled(setting.value >= setting.max)
                .accessibilityLabel("more \(setting.label.lowercased())")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
