import SwiftUI

/// Room chat with the same safety tools as the web: mute for me, report,
/// and host controls (chat off, mute in room, remove, ban).
struct ChatView: View {
    let session: RoomSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showPlayers = false
    @State private var target: Target?
    @State private var notice = ""
    @State private var busy = false
    @FocusState private var inputFocused: Bool

    struct Target: Identifiable, Equatable {
        let id: String
        let name: String
        var messageId: Int?
    }

    private static let reportReasons: [(String, String)] = [
        ("harassment", "Bullying or harassment"),
        ("sexual-content", "Sexual or inappropriate content"),
        ("hate", "Hate or slurs"),
        ("personal-info", "Personal information or unsafe contact"),
        ("spam", "Spam"),
        ("cheating", "Cheating"),
        ("other", "Something else"),
    ]

    var body: some View {
        let room = session.room
        let myId = session.seat?.playerId
        VStack(spacing: 0) {
            header(room)
            if showPlayers, let room { playersList(room, myId: myId) }
            messages(room, myId: myId)
            if !notice.isEmpty {
                Text(notice).font(.pixel(17)).foregroundStyle(Palette.cyan).padding(.horizontal, 16).padding(.vertical, 4)
            }
            if let disabled = disabledReason(room, myId: myId) {
                Text(disabled).font(.pixel(17)).foregroundStyle(Palette.drift).padding(.vertical, 4)
            }
            inputBar(room, myId: myId)
        }
        .background(Palette.panelSolid.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $target) { target in
            PlayerActionsView(session: session, target: target, reasons: Self.reportReasons) { message in
                notice = message
            }
        }
        .onAppear { session.markChatRead() }
        .onChange(of: room?.chat.last?.id) { _, _ in session.markChatRead() }
    }

    private func header(_ room: Room?) -> some View {
        HStack(spacing: 8) {
            Text("CHAT").pixelLabel(24, color: Palette.foam)
            Spacer()
            Button(showPlayers ? "PLAYERS ▴" : "PLAYERS ▾") { showPlayers.toggle() }
                .buttonStyle(QuietButtonStyle(size: 17))
            if session.isHost, let room {
                Button(room.chatEnabled ? "TURN CHAT OFF" : "TURN CHAT ON") {
                    run(["type": "chat-enabled", "enabled": !room.chatEnabled])
                }
                .buttonStyle(QuietButtonStyle(color: Palette.gold, size: 17))
                .disabled(busy)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close chat")
        }
        .padding(16)
    }

    private func playersList(_ room: Room, myId: String?) -> some View {
        let others = room.players.filter { $0.id != myId && !$0.removed }
        return VStack(alignment: .leading, spacing: 6) {
            if others.isEmpty {
                Text("No other players yet.").font(.pixel(18)).foregroundStyle(Palette.drift)
            }
            ForEach(others) { player in
                Button {
                    target = Target(id: player.id, name: player.name)
                } label: {
                    HStack {
                        Text(player.name).font(.pixel(20)).foregroundStyle(Palette.buddy(player.character))
                        Spacer()
                        Text(session.muted.contains(player.id) ? "muted for you"
                             : player.chatMuted ? "muted by host"
                             : player.id == room.hostId ? "host" : "")
                            .font(.pixel(16))
                            .foregroundStyle(Palette.drift)
                        Image(systemName: "chevron.right").foregroundStyle(Palette.drift)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func messages(_ room: Room?, myId: String?) -> some View {
        let list = (room?.chat ?? []).filter { $0.playerId == nil || !session.muted.contains($0.playerId!) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if list.isEmpty {
                        Text("Say hi to the ring. Keep it friendly; no links or personal details.")
                            .font(.pixel(18))
                            .foregroundStyle(Palette.drift)
                    }
                    ForEach(list) { message in
                        messageRow(message, room: room, myId: myId)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear {
                if let id = list.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: list.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, room: Room?, myId: String?) -> some View {
        if message.playerId == nil {
            Text(message.text)
                .font(.pixel(17))
                .foregroundStyle(Palette.drift)
        } else {
            let character = room?.player(message.playerId)?.character ?? Buddy.defaultId
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text(message.name).foregroundStyle(Palette.buddy(character)) + Text("  ") + Text(message.text).foregroundStyle(Palette.foam))
                    .font(.pixel(20))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if message.playerId != myId {
                    Button {
                        target = Target(id: message.playerId!, name: message.name, messageId: message.id)
                    } label: {
                        Text("···").font(.pixel(20)).foregroundStyle(Palette.drift)
                            .frame(width: 36, height: 28)
                    }
                    .accessibilityLabel("Options for \(message.name)'s message")
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(message.playerId == myId ? Palette.cyan.opacity(0.08) : .clear)
        }
    }

    private func disabledReason(_ room: Room?, myId: String?) -> String? {
        guard let room else { return nil }
        if !room.chatEnabled { return "The host has turned chat off." }
        if room.player(myId)?.chatMuted == true { return "The host has muted you in this room." }
        return nil
    }

    private func inputBar(_ room: Room?, myId: String?) -> some View {
        let blocked = disabledReason(room, myId: myId) != nil
        return HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("say something…").foregroundStyle(Palette.drift))
                .font(.pixel(22))
                .foregroundStyle(Palette.foam)
                .tint(Palette.cyan)
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit(sendDraft)
                .onChange(of: draft) { _, value in
                    if value.count > Party.maxChatLength { draft = String(value.prefix(Party.maxChatLength)) }
                }
                .disabled(blocked)
                .padding(.horizontal, 10)
                .frame(height: 46)
                .background(Palette.abyss)
                .overlay(Rectangle().stroke(Palette.pfLine, lineWidth: 2))
                .accessibilityLabel("Chat message")
            Button("SEND", action: sendDraft)
                .buttonStyle(BeginButtonStyle(color: Palette.cyan, height: 46))
                .frame(width: 90)
                .disabled(busy || blocked || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sent = draft
        busy = true
        Task {
            let result = await session.act(["type": "chat", "text": text])
            busy = false
            if result.ok {
                if draft == sent { draft = "" }
                inputFocused = true
            } else {
                notice = result.error ?? "That didn't go through. Please try again."
            }
        }
    }

    private func run(_ action: [String: Any]) {
        busy = true
        Task {
            let result = await session.act(action)
            busy = false
            if !result.ok { notice = result.error ?? "That didn't go through. Please try again." }
        }
    }
}

/// Mute / report / host moderation for one player.
struct PlayerActionsView: View {
    let session: RoomSession
    let target: ChatView.Target
    let reasons: [(String, String)]
    var onNotice: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reporting = false
    @State private var reason = "harassment"
    @State private var confirm: String?
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        let player = session.room?.player(target.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(target.name).font(.pixel(30)).foregroundStyle(Palette.foam)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Close player controls")
            }
            if reporting {
                Text("Report reason").pixelLabel(17)
                Picker("Report reason", selection: $reason) {
                    ForEach(reasons, id: \.0) { item in Text(item.1).tag(item.0) }
                }
                .pickerStyle(.wheel)
                .frame(height: 120)
                Text("The message and recent room context will be saved for review.")
                    .font(.pixel(17)).foregroundStyle(Palette.drift)
                HStack {
                    Button("SEND REPORT") {
                        var action: [String: Any] = ["type": "report", "playerId": target.id, "reason": reason]
                        if let messageId = target.messageId { action["messageId"] = messageId }
                        perform(action) {
                            onNotice("Report saved. Thank you. You can also mute this player for yourself.")
                        }
                    }
                    .buttonStyle(BeginButtonStyle(color: Palette.pink, height: 48))
                    Button("CANCEL") { reporting = false }
                        .buttonStyle(QuietButtonStyle(color: Palette.foam))
                }
                .disabled(busy)
            } else if let confirm {
                Text(confirm == "ban"
                     ? "Ban this player from the room? They will be removed and this device cannot rejoin."
                     : "Remove this player? They can join again with a new seat.")
                    .font(.pixel(20)).foregroundStyle(Palette.foam)
                HStack {
                    Button(confirm == "ban" ? "BAN PLAYER" : "REMOVE PLAYER") {
                        perform(["type": "moderate", "playerId": target.id, "action": confirm]) {}
                    }
                    .buttonStyle(BeginButtonStyle(color: Palette.danger, height: 48))
                    Button("CANCEL") { self.confirm = nil }
                        .buttonStyle(QuietButtonStyle(color: Palette.foam))
                }
                .disabled(busy)
            } else {
                VStack(spacing: 10) {
                    Button(session.muted.contains(target.id) ? "UNMUTE FOR ME" : "MUTE FOR ME") {
                        session.toggleMute(target.id)
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle(color: Palette.cyan))
                    Button("REPORT") { reporting = true }
                        .buttonStyle(QuietButtonStyle(color: Palette.pink))
                    if session.isHost, let player, !player.removed {
                        Button(player.chatMuted ? "UNMUTE IN ROOM" : "MUTE IN ROOM") {
                            perform(["type": "moderate", "playerId": target.id,
                                     "action": player.chatMuted ? "unmute" : "mute"]) {}
                        }
                        .buttonStyle(QuietButtonStyle(color: Palette.gold))
                        Button("REMOVE") { confirm = "remove" }
                            .buttonStyle(QuietButtonStyle(color: Palette.gold))
                        Button("BAN FROM ROOM") { confirm = "ban" }
                            .buttonStyle(QuietButtonStyle(color: Palette.danger))
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(busy)
            }
            if !error.isEmpty {
                Text(error).font(.pixel(17)).foregroundStyle(Palette.pink)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(Palette.panelSolid.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func perform(_ action: [String: Any], then: @escaping () -> Void) {
        busy = true
        error = ""
        Task {
            let result = await session.act(action)
            busy = false
            if result.ok {
                then()
                dismiss()
            } else {
                error = result.error ?? "That didn't go through. Please try again."
            }
        }
    }
}
