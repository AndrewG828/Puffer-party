import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// Krillion palette (from the site's CSS tokens).
enum Palette {
    static let abyss = Color(hex: 0x050a14)
    static let shallow = Color(hex: 0x101d33)
    static let line = Color(hex: 0x1b2c47)
    static let pfLine = Color(hex: 0x1b3050)
    static let panel = Color(hex: 0x0b1526, opacity: 0.92)
    static let panelSolid = Color(hex: 0x0b1526)
    static let foam = Color(hex: 0xe8f1ff)
    static let drift = Color(hex: 0x7d93b8)
    static let cyan = Color(hex: 0x4de3ff)
    static let pink = Color(hex: 0xff5d8f)
    static let gold = Color(hex: 0xffd166)
    static let meterEmpty = Color(hex: 0x12233d)
    static let meterUnknown = Color(hex: 0x3a5378)
    static let danger = Color(hex: 0xff5252)
    static let ok = Color(hex: 0x6dffb0)

    static func tier(_ id: String?) -> Color {
        guard let tier = Tier.find(id) else { return meterUnknown }
        return Color(hex: tier.colorHex)
    }

    static func buddy(_ id: String) -> Color {
        Color(hex: Buddy.find(id).colorHex)
    }
}

/// VT323, the site's pixel font (bundled, SIL OFL).
extension Font {
    static func pixel(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("VT323", size: size, relativeTo: style)
    }
}

extension View {
    /// Wide letter-spaced pixel label, like the site's headings.
    func pixelLabel(_ size: CGFloat = 18, color: Color = Palette.drift, tracking: CGFloat = 3) -> some View {
        font(.pixel(size, relativeTo: .caption))
            .tracking(tracking)
            .foregroundStyle(color)
    }

    /// Dark bordered panel with notched corners.
    func pixelPanel(padding: CGFloat = 16, border: Color = Palette.pfLine) -> some View {
        self.padding(padding)
            .background(NotchedRect(notch: 6).fill(Palette.panel))
            .overlay(NotchedRect(notch: 6).stroke(border, lineWidth: 2))
    }
}

/// Rectangle with 45° clipped corners (pixel-art panel shape).
struct NotchedRect: Shape {
    var notch: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let n = min(notch, rect.width / 4, rect.height / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + n, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - n, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + n))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - n))
        p.addLine(to: CGPoint(x: rect.maxX - n, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + n, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - n))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + n))
        p.closeSubpath()
        return p
    }
}

/// Big call-to-action button ("▶ RATED ◀", "▼ HOST A ROOM ▼").
struct BeginButtonStyle: ButtonStyle {
    var color: Color = Palette.pink
    var textColor: Color = Palette.abyss
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        BeginButtonBody(configuration: configuration, color: color, textColor: textColor, height: height)
    }

    private struct BeginButtonBody: View {
        let configuration: Configuration
        let color: Color
        let textColor: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.pixel(26, relativeTo: .headline))
                .tracking(3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(isEnabled ? textColor : Palette.drift)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(NotchedRect(notch: 5).fill(isEnabled ? color : Palette.shallow))
                .overlay(NotchedRect(notch: 5).stroke(isEnabled ? color.opacity(0.6) : Palette.line, lineWidth: 2))
                .offset(y: configuration.isPressed ? 2 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Outlined secondary button.
struct QuietButtonStyle: ButtonStyle {
    var color: Color = Palette.cyan
    var size: CGFloat = 20
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, color: color, size: size, fill: fill)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        let color: Color
        let size: CGFloat
        let fill: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.pixel(size, relativeTo: .body))
                .tracking(2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(isEnabled ? (fill ? Palette.abyss : color) : Palette.drift.opacity(0.6))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(NotchedRect(notch: 4).fill(fill && isEnabled ? color : Palette.abyss.opacity(0.6)))
                .overlay(NotchedRect(notch: 4).stroke(isEnabled ? color.opacity(0.7) : Palette.line, lineWidth: 2))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Square icon button used in the HUD.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Palette.foam.opacity(0.85))
            .frame(width: 44, height: 44)
            .background(NotchedRect(notch: 4).fill(Palette.panelSolid.opacity(0.9)))
            .overlay(NotchedRect(notch: 4).stroke(Palette.pfLine, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Pixel heart (same 7×6 grid as the web's HEART_SVG).
struct PixelHeart: View {
    var color: Color = Palette.pink
    var size: CGFloat = 12

    var body: some View {
        Canvas { context, canvas in
            let cell = canvas.width / 7
            let rects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (1, 0, 2, 1), (4, 0, 2, 1), (0, 1, 7, 2), (1, 3, 5, 1), (2, 4, 3, 1), (3, 5, 1, 1),
            ]
            for r in rects {
                context.fill(Path(CGRect(x: r.0 * cell, y: r.1 * cell, width: r.2 * cell, height: r.3 * cell)),
                             with: .color(color))
            }
        }
        .frame(width: size, height: size * 6 / 7)
        .accessibilityHidden(true)
    }
}

/// Animated "KRILLION / PUFFER PARTY" title.
struct PartyTitle: View {
    var compact = false
    @State private var bob = false

    var body: some View {
        VStack(spacing: compact ? 2 : 6) {
            HStack(spacing: 0) {
                ForEach(Array("KRILLION".enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(.pixel(compact ? 44 : 64, relativeTo: .largeTitle))
                        .foregroundStyle(Palette.foam)
                        .shadow(color: Palette.pink, radius: 0, x: -2, y: 1)
                        .shadow(color: Palette.cyan, radius: 0, x: 2, y: -1)
                        .offset(y: bob ? -3 : 3)
                        .animation(.easeInOut(duration: 1.1).repeatForever().delay(0.18 * Double(index)), value: bob)
                }
            }
            Text("PUFFER PARTY")
                .pixelLabel(compact ? 22 : 28, color: Palette.cyan, tracking: 8)
            if !compact {
                Text("pass the puffer · don't let it pop on you")
                    .font(.pixel(19))
                    .foregroundStyle(Palette.drift)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Krillion Puffer Party")
        .onAppear { bob = true }
    }
}

/// Reef art behind every screen.
struct ReefBackground: View {
    var dim: Double = 0.35

    var body: some View {
        GeometryReader { geo in
            Image(geo.size.width > geo.size.height ? "reef-d" : "reef-m")
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(Palette.abyss.opacity(dim))
        }
        .ignoresSafeArea()
        .background(Palette.abyss)
        .accessibilityHidden(true)
    }
}

/// Small coloured chip, e.g. a tier label.
struct Chip: View {
    let text: String
    var color: Color = Palette.cyan

    var body: some View {
        Text(text)
            .font(.pixel(15, relativeTo: .caption2))
            .tracking(1.5)
            .foregroundStyle(Palette.abyss)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color)
    }
}
