import SwiftUI

/// The puffer itself: swells through 4 sprites as it is held.
struct PufferSprite: View {
    let level: Int
    let sleeping: Bool
    var size: CGFloat = 80
    @State private var bob = false

    var body: some View {
        let sprite = PufferLevel.sprite(for: level)
        Image(sleeping ? "puffer-sleep" : "puffer-\(sprite.image)")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(sleeping ? 0.9 : sprite.scale)
            .offset(y: bob ? -3 : 3)
            .animation(.spring(response: 0.25, dampingFraction: 0.45), value: level)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: bob)
            .onAppear { bob = true }
            .accessibilityHidden(true)
    }
}

/// "POP!" burst when someone runs out of time.
struct PopBurst: View {
    let key: Int
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                Circle()
                    .fill(i.isMultiple(of: 2) ? Palette.gold : Palette.foam)
                    .frame(width: 6, height: 6)
                    .offset(x: go ? cos(angle) * 60 : 0, y: go ? sin(angle) * 60 : 0)
                    .opacity(go ? 0 : 1)
            }
            Text("POP!")
                .font(.pixel(44))
                .foregroundStyle(Palette.pink)
                .shadow(color: Palette.abyss, radius: 0, x: 2, y: 2)
                .scaleEffect(go ? 1.3 : 0.4)
                .opacity(go ? 0 : 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { go = true }
        }
        .accessibilityHidden(true)
    }
}

/// Circular heart meter: coloured slices for each answer's tier, with the
/// heart count in the middle.
struct HeartMeterRing: View {
    let segments: [MeterSegment]
    let target: Int
    let lives: Int
    var size: CGFloat = 58
    var hot = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.meterEmpty, lineWidth: 6)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(Palette.tier(arc.tier), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            HStack(spacing: 3) {
                PixelHeart(color: Palette.pink, size: 14)
                Text("\(lives)")
                    .font(.pixel(24))
                    .foregroundStyle(Palette.foam)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Palette.abyss.opacity(0.85)))
        .overlay(Circle().stroke(hot ? Palette.pink : Palette.pfLine, lineWidth: 2).padding(-4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lives) \(lives == 1 ? "heart" : "hearts"), meter \(Int(fraction * 100)) percent to the next heart")
    }

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(segments.reduce(0) { $0 + $1.amount }) / Double(target))
    }

    private var arcs: [(start: Double, end: Double, tier: String?)] {
        guard target > 0 else { return [] }
        var out: [(start: Double, end: Double, tier: String?)] = []
        var position = 0.0
        for segment in segments {
            let end = min(1, position + Double(segment.amount) / Double(target))
            out.append((start: position, end: end, tier: segment.tier))
            position = end
        }
        return out
    }
}
