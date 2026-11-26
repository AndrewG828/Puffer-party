import UIKit

/// Haptic cues that stand in for the web game's sound effects.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notify = UINotificationFeedbackGenerator()

    static func yourTurn() {
        notify.notificationOccurred(.warning)
    }

    static func soft() {
        light.impactOccurred(intensity: 0.5)
    }

    static func tick(level: Int) {
        rigid.impactOccurred(intensity: min(1, 0.35 + Double(level) * 0.13))
    }

    static func reject() {
        notify.notificationOccurred(.error)
    }

    static func spare() {
        light.impactOccurred(intensity: 0.9)
    }

    static func pop(mine: Bool) {
        heavy.impactOccurred(intensity: mine ? 1 : 0.6)
    }

    static func begin() {
        rigid.impactOccurred(intensity: 0.7)
    }

    static func category() {
        light.impactOccurred(intensity: 0.7)
    }

    static func win() {
        notify.notificationOccurred(.success)
    }

    static func tap() {
        light.impactOccurred(intensity: 0.4)
    }
}
