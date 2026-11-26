import SwiftUI
import UIKit

@main
struct PufferPartyApp: App {
    @State private var router = AppRouter()
    @State private var verification = VerificationCenter()

    init() {
        AppAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView(router: router, verification: verification)
                .preferredColorScheme(.dark)
                .onAppear { verification.install() }
                .onOpenURL { router.open($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { router.open(url) }
                }
        }
    }
}

enum Route: Hashable {
    case room(code: String, grant: Seat?)
}

@MainActor
@Observable
final class AppRouter {
    var path: [Route] = []
    let door = DoorModel()

    func openRoom(_ code: String, grant: Seat?) {
        if case .room(let current, _)? = path.last, current == code { return }
        path = [.room(code: code, grant: grant)]
    }

    /// krillion.io/party/ABCD, pufferparty://party/ABCD or pufferparty://ABCD.
    func open(_ url: URL) {
        let parts = ([url.host ?? ""] + url.pathComponents).filter { !$0.isEmpty && $0 != "/" }
        guard let last = parts.last, let code = Party.normalizeCode(last) else { return }
        openRoom(code, grant: nil)
    }
}

struct RootView: View {
    @Bindable var router: AppRouter
    @Bindable var verification: VerificationCenter

    var body: some View {
        NavigationStack(path: $router.path) {
            DoorView(model: router.door) { code, seat in
                router.openRoom(code, grant: seat)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .room(let code, let grant):
                    RoomScreen(code: code, grant: grant)
                        .id(code)
                }
            }
        }
        .tint(Palette.cyan)
        .sheet(item: $verification.request) { request in
            VerificationSheet(center: verification, request: request)
        }
    }
}

enum AppAppearance {
    static func apply() {
        let pixel = UIFont(name: "VT323", size: 18) ?? .systemFont(ofSize: 15)
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(Palette.cyan)
        segmented.backgroundColor = UIColor(Palette.abyss)
        segmented.setTitleTextAttributes([.font: pixel.withSize(22), .foregroundColor: UIColor(Palette.foam)], for: .normal)
        segmented.setTitleTextAttributes([.font: pixel.withSize(22), .foregroundColor: UIColor(Palette.abyss)], for: .selected)
    }
}
