import SwiftUI

/// Route target for a room code. Owns the session for its lifetime.
struct RoomScreen: View {
    @State private var session: RoomSession
    @Environment(\.dismiss) private var dismiss

    init(code: String, grant: Seat?) {
        _session = State(initialValue: RoomSession(code: code, grant: grant))
    }

    var body: some View {
        Group {
            switch session.screen {
            case .playing:
                GameView(session: session)
            case .joinForm:
                JoinRingView(session: session, onBack: { dismiss() })
            case .swimmingIn:
                CenteredMessage(text: "swimming in…", loading: true)
            case .leaving:
                CenteredMessage(text: "see you")
            case .findingTable:
                CenteredMessage(text: "finding a table…", loading: true)
            case .paused:
                RoomMessageView(code: session.code, text: Party.pausedMessage, onRetry: nil, onBack: { dismiss() })
            case .message(let text):
                RoomMessageView(code: session.code, text: text, onRetry: { session.retry() }, onBack: { dismiss() })
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            session.onExit = { dismiss() }
            session.start()
        }
        .onDisappear { session.stop() }
    }
}

struct CenteredMessage: View {
    let text: String
    var loading = false

    var body: some View {
        ZStack {
            ReefBackground(dim: 0.45)
            LoadingPill(text: text, large: true)
                .opacity(loading ? 1 : 0.9)
        }
    }
}

/// Terminal room message ("this room closed", removed, paused...).
struct RoomMessageView: View {
    let code: String
    let text: String
    var onRetry: (() -> Void)?
    var onBack: () -> Void

    var body: some View {
        ZStack {
            ReefBackground(dim: 0.5)
            VStack(spacing: 20) {
                PartyTitle(compact: true)
                VStack(alignment: .leading, spacing: 14) {
                    Text("ROOM \(code)").pixelLabel(22, color: Palette.foam)
                    Text(text)
                        .font(.pixel(24))
                        .foregroundStyle(Palette.foam)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onRetry, text.contains("try again") {
                        Button("TRY AGAIN", action: onRetry)
                            .buttonStyle(BeginButtonStyle(color: Palette.cyan, height: 48))
                    }
                    Button("▸ back to the rooms", action: onBack)
                        .font(.pixel(22))
                        .foregroundStyle(Palette.cyan)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixelPanel()
            }
            .padding(16)
            .frame(maxWidth: 520)
        }
    }
}

/// "JOIN THE RING": opened from an invite link without a seat yet.
struct JoinRingView: View {
    let session: RoomSession
    var onBack: () -> Void
    @State private var name = PartyStorage.name
    @State private var character = PartyStorage.character
    @State private var showHowTo = false
    @FocusState private var focus: Field?

    enum Field { case name }

    var body: some View {
        ZStack {
            ReefBackground(dim: 0.45)
            ScrollView {
                VStack(spacing: 18) {
                    PartyTitle()
                        .padding(.top, 32)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("JOIN THE RING").pixelLabel(22, color: Palette.foam)
                            Spacer()
                            Button("HOW TO PLAY") { showHowTo = true }
                                .font(.pixel(18))
                                .foregroundStyle(Palette.foam)
                                .underline()
                        }
                        Text(session.code)
                            .font(.pixel(56))
                            .tracking(10)
                            .foregroundStyle(Palette.cyan)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Room \(session.code)")
                        IdentityFields(
                            name: $name,
                            character: character,
                            streak: PartyStorage.maxStreak,
                            onCharacter: { id in
                                character = id
                                PartyStorage.character = id
                            },
                            submit: { session.joinFromForm(name: name, character: character) },
                            focus: $focus,
                            focusValue: .name
                        )
                        Button(session.joining ? "SWIMMING IN…" : "▼ TAKE A SEAT ▼") {
                            focus = nil
                            session.joinFromForm(name: name, character: character)
                        }
                        .buttonStyle(BeginButtonStyle(color: Palette.pink))
                        .disabled(session.joining)
                        .padding(.top, 8)
                        if let error = session.joinError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(.pixel(19)).foregroundStyle(Palette.pink)
                                if let room = session.joinSeatedElsewhere {
                                    Button("LEAVE ROOM \(room) AND CONTINUE") {
                                        session.joinFromForm(name: name, character: character, replace: true)
                                    }
                                    .buttonStyle(QuietButtonStyle(color: Palette.pink, size: 17))
                                    .disabled(session.joining)
                                }
                            }
                        }
                        Button("▸ other rooms", action: onBack)
                            .font(.pixel(21))
                            .foregroundStyle(Palette.cyan)
                    }
                    .pixelPanel()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showHowTo) { HowToPlayView() }
    }
}
