import SwiftUI

struct HowToPlayView: View {
    @Environment(\.dismiss) private var dismiss

    private static let rules = [
        "Answer the question before the puffer explodes on you.",
        "Rarer answers get you closer to an extra heart.",
        "No reusing answers for the current question.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PUFFER PARTY").pixelLabel(16, color: Palette.cyan)
                    Text("HOW TO PLAY").pixelLabel(30, color: Palette.foam)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Close how to play")
            }
            ForEach(Array(Self.rules.enumerated()), id: \.offset) { index, rule in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1).")
                        .font(.pixel(26))
                        .foregroundStyle(Palette.pink)
                    Text(rule)
                        .font(.pixel(24))
                        .foregroundStyle(Palette.foam)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                ForEach(Tier.all.filter { $0.id != "tooclever" }, id: \.id) { tier in
                    VStack(spacing: 2) {
                        Image(tier.imageName)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(height: 30)
                        Text("+\(tier.score)")
                            .font(.pixel(15))
                            .foregroundStyle(Color(hex: tier.colorHex))
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(tier.name): \(tier.score) points")
                }
            }
            Spacer(minLength: 0)
            Button("GOT IT") { dismiss() }
                .buttonStyle(BeginButtonStyle(color: Palette.cyan))
        }
        .padding(24)
        .background(Palette.panelSolid.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
