import SwiftUI

/// "YOUR NAME" field plus the buddy picker (locked buddies show the streak
/// that unlocks them, as on the web).
struct IdentityFields<F: Hashable>: View {
    @Binding var name: String
    let character: String
    let streak: Int
    var onCharacter: (String) -> Void
    var onSubmit: () -> Void
    var focus: FocusState<F?>.Binding
    let focusValue: F

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 92), spacing: 8)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR NAME").pixelLabel(17)
            TextField("", text: $name, prompt: Text("what the ring calls you").foregroundStyle(Palette.drift.opacity(0.7)))
                .font(.pixel(26))
                .foregroundStyle(Palette.foam)
                .tint(Palette.cyan)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.nickname)
                .submitLabel(.go)
                .focused(focus, equals: focusValue)
                .onSubmit(onSubmit)
                .onChange(of: name) { _, value in
                    if value.count > Party.maxNameLength { name = String(value.prefix(Party.maxNameLength)) }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(Palette.abyss.opacity(0.7))
                .overlay(Rectangle().stroke(focus.wrappedValue == focusValue ? Palette.cyan : Palette.pfLine, lineWidth: 2))
                .accessibilityLabel("Your name")

            Text("YOUR BUDDY").pixelLabel(17)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Buddy.all) { buddy in
                    BuddyKey(buddy: buddy, selected: buddy.id == character,
                             locked: !buddy.isUnlocked(streak: streak)) {
                        Haptics.tap()
                        onCharacter(buddy.id)
                    }
                }
            }
        }
    }
}

struct BuddyKey: View {
    let buddy: Buddy
    let selected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(buddy.sprite)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(height: 40)
                    .colorMultiply(locked ? .black : .white)
                    .opacity(locked ? 0.55 : 1)
                Text(buddy.keyLabel)
                    .font(.pixel(16))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(locked ? Palette.drift : Palette.foam)
                if locked {
                    Text("\(buddy.unlockStreak)-day")
                        .font(.pixel(14))
                        .foregroundStyle(Palette.drift)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(Palette.abyss.opacity(0.6))
            .overlay(Rectangle().stroke(selected ? Palette.cyan : Palette.pfLine, lineWidth: selected ? 3 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(locked ? "\(buddy.name), unlocks at a \(buddy.unlockStreak)-day streak" : buddy.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
