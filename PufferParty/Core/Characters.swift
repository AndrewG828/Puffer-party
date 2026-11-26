import Foundation

/// The buddies players can sit as. Same ids, names, colours and unlock streaks
/// as the web client (`MASCOT_CHARACTERS`).
struct Buddy: Identifiable, Equatable {
    let id: String
    let name: String
    let keyLabel: String
    let colorHex: UInt32
    let blub: String
    let unlockStreak: Int
    /// Asset names in the catalog.
    let sprite: String
    let goldSprite: String

    static let defaultId = "krill"

    static let all: [Buddy] = [
        .init(id: "krill", name: "The Krill", keyLabel: "KRILL", colorHex: 0xff5d8f, blub: "blub!", unlockStreak: 0,
              sprite: "buddy-krill", goldSprite: "buddy-krill-gold"),
        .init(id: "schooler", name: "Schooler", keyLabel: "SCHOOLER", colorHex: 0x4de3ff, blub: "glub!", unlockStreak: 5,
              sprite: "buddy-schooler", goldSprite: "buddy-schooler-gold"),
        .init(id: "rare", name: "Rare Squid", keyLabel: "SQUID", colorHex: 0xff5252, blub: "blorp!", unlockStreak: 14,
              sprite: "buddy-rare", goldSprite: "buddy-rare-gold"),
        .init(id: "deepcut", name: "Deep Cut Angler", keyLabel: "ANGLER", colorHex: 0x9d7bff, blub: "chomp!", unlockStreak: 30,
              sprite: "buddy-deepcut", goldSprite: "buddy-deepcut-gold"),
        .init(id: "evil-krill", name: "Evil Krill", keyLabel: "EVIL", colorHex: 0xff303b, blub: "mwahaha!", unlockStreak: 45,
              sprite: "buddy-evil-krill", goldSprite: "buddy-evil-krill-gold"),
        .init(id: "hackmanite", name: "Hackmanite", keyLabel: "HACKMANITE", colorHex: 0xdfefee, blub: "glimmer!", unlockStreak: 60,
              sprite: "buddy-hackmanite", goldSprite: "buddy-hackmanite-gold"),
        .init(id: "fossil-krill", name: "Fossil Krill", keyLabel: "FOSSIL", colorHex: 0xe8cfa4, blub: "rattle!", unlockStreak: 75,
              sprite: "buddy-fossil-krill", goldSprite: "buddy-fossil-krill-gold"),
        .init(id: "mantis-shrimp", name: "Mantis Shrimp", keyLabel: "MANTIS", colorHex: 0xed9359, blub: "pow!", unlockStreak: 100,
              sprite: "buddy-mantis-shrimp", goldSprite: "buddy-mantis-shrimp-gold"),
        .init(id: "leviathan", name: "Leviathan", keyLabel: "LEVIATHAN", colorHex: 0xb4f542, blub: "grrrblub!", unlockStreak: 150,
              sprite: "buddy-leviathan", goldSprite: "buddy-leviathan-gold"),
    ]

    static func find(_ id: String?) -> Buddy {
        all.first { $0.id == id } ?? all[0]
    }

    static func isValid(_ id: String?) -> Bool {
        all.contains { $0.id == id }
    }

    func isUnlocked(streak: Int) -> Bool {
        unlockStreak == 0 || streak >= unlockStreak
    }
}
