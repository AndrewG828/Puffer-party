import Foundation

/// Reconnect delays, same curve as `createPartyReconnectBackoff`.
struct ReconnectBackoff {
    private var attempt = 0
    private var liveSince: Date?
    let quickFirst: Bool

    init(quickFirst: Bool = false) {
        self.quickFirst = quickFirst
    }

    mutating func receivedRoom() {
        if liveSince == nil { liveSince = Date() }
    }

    /// Milliseconds to wait before the next connection attempt.
    mutating func disconnected() -> Int {
        if let since = liveSince, Date().timeIntervalSince(since) >= 30 { attempt = 0 }
        liveSince = nil
        attempt = min(attempt + 1, 6)
        let step = quickFirst ? attempt - 1 : attempt
        if step == 0 { return Int((250 + 1000 * Double.random(in: 0..<1)).rounded()) }
        let base = min(24000.0, 3000.0 * pow(2.0, Double(step - 1)))
        return Int((base * (1 + 0.25 * Double.random(in: 0..<1))).rounded())
    }
}

/// One coloured slice of a heart meter.
struct MeterSegment: Equatable {
    let tier: String?
    let amount: Int
}

enum HeartMeter {
    static func feed(_ segments: [MeterSegment], tier: String?) -> [MeterSegment] {
        segments + [MeterSegment(tier: tier, amount: Tier.meterPoints(tier))]
    }

    /// Makes the local segments add up to the server's meter value.
    static func reconcile(_ segments: [MeterSegment], meter: Int, target: Int) -> [MeterSegment] {
        let goal = max(0, min(target, meter))
        let sum = segments.reduce(0) { $0 + $1.amount }
        if sum == goal { return segments }
        if sum < goal { return [MeterSegment(tier: nil, amount: goal - sum)] + segments }
        var out: [MeterSegment] = []
        var filled = 0
        for seg in segments.reversed() where filled < goal {
            let amount = min(seg.amount, goal - filled)
            out.insert(MeterSegment(tier: seg.tier, amount: amount), at: 0)
            filled += amount
        }
        return out
    }
}

/// How swollen the puffer looks (0...5) for the time it has been held.
/// The thresholds are jittered by a PRNG seeded from `holderSince`, exactly
/// as in the web engine, so every client sees the same swell.
enum PufferLevel {
    static let baseThresholds: [Double] = [1.2, 2.5, 3.9, 5.4, 7.1]

    static func thresholds(holderSince: Double?) -> [Double] {
        guard let holderSince else { return baseThresholds }
        var state = UInt32(truncatingIfNeeded: Int64(holderSince.rounded(.down))) ^ 0x9e37_79b9
        func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var e = state
            e = (e ^ (e >> 15)) &* (1 | e)
            e ^= e &+ ((e ^ (e >> 7)) &* (61 | e))
            return Double(e ^ (e >> 14)) / 4_294_967_296.0
        }
        return baseThresholds.map { $0 + (0.55 * next() - 0.25) }
    }

    /// `heldSeconds`: seconds since `holderSince` on the server clock.
    static func level(heldSeconds: Double, thresholds: [Double]) -> Int {
        guard heldSeconds >= 0 else { return 0 }
        return min(5, thresholds.filter { heldSeconds >= $0 }.count)
    }

    /// Which puffer sprite (0...3) and scale to draw for a level.
    static func sprite(for level: Int) -> (image: Int, scale: Double) {
        let table: [(Int, Double)] = [(0, 0.9), (0, 1.04), (1, 0.95), (1, 1.04), (2, 1.0), (3, 1.03)]
        let entry = table[max(0, min(5, level))]
        return (entry.0, entry.1)
    }
}

/// Typing statistics the server uses for its bot check, sent with every
/// answer (the web client's `input` report).
struct InputTelemetry {
    private var keys = 0
    private var pastes = 0
    private var other = 0
    private var gaps: [Double] = []
    private var lastKeyAt: Double?
    private var lastChar = ""

    mutating func reset() {
        self = InputTelemetry()
    }

    /// Call for every edit. `inserted` is the replacement text the keyboard
    /// produced, `timestamp` milliseconds from a monotonic clock.
    mutating func note(inserted: String, removedLength: Int, timestamp: Double, resultingText: String) {
        if resultingText.isEmpty { reset(); return }
        if inserted.count == 1 && removedLength == 0 {
            keys = min(10_000, keys + 1)
            if let last = lastKeyAt, inserted != lastChar {
                let gap = timestamp - last
                if gap >= 0 && gap < 2000 && gaps.count < 60 { gaps.append(gap) }
            }
            lastKeyAt = timestamp
            lastChar = inserted
            return
        }
        if inserted.count > 1 {
            pastes = min(10_000, pastes + 1)
        } else {
            other = min(10_000, other + 1)
        }
        lastKeyAt = nil
    }

    func report() -> [String: Any] {
        let count = gaps.count
        let mean: Double? = count > 0 ? gaps.reduce(0, +) / Double(count) : nil
        var cv: Any = NSNull()
        if count >= 2, let mean, mean > 0 {
            func quantized(_ value: Double, _ step: Double) -> Bool {
                abs(value / step - (value / step).rounded()) * step < 0.05
            }
            let allQuantized = gaps.allSatisfy { quantized($0, 10) || quantized($0, 50.0 / 3.0) }
            if !allQuantized {
                let variance = gaps.reduce(0) { $0 + pow($1 - mean, 2) } / Double(count - 1)
                cv = (sqrt(variance) / mean * 100).rounded() / 100
            }
        }
        var meanValue: Any = NSNull()
        if let mean { meanValue = Int(mean.rounded()) }
        return [
            "keys": keys,
            "pastes": pastes,
            "other": other,
            "synthetic": 0,
            "gaps": count,
            "mean": meanValue,
            "cv": cv,
        ]
    }
}
