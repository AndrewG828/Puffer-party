import SwiftUI
import WebKit

/// Presents the Cloudflare Turnstile bot check the party token endpoint asks
/// for ("A quick check before you join"), and hands its token back.
@MainActor
@Observable
final class VerificationCenter {
    struct Request: Identifiable {
        let id = UUID()
        let siteKey: String
        let guestId: String
    }

    var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<String, Error>?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func install() {
        PartyAPI.shared.verifier = { [weak self] siteKey, guestId in
            guard let self else { throw PartyVerificationError(message: "Verification is unavailable.") }
            return try await self.verify(siteKey: siteKey, guestId: guestId)
        }
    }

    private func verify(siteKey: String, guestId: String) async throws -> String {
        finish(.failure(PartyVerificationError(message: "Verification cancelled. Choose Play when you're ready.")))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.request = Request(siteKey: siteKey, guestId: guestId)
            self.timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(PartyVerificationError(message: "Verification timed out. Please try again.")))
            }
        }
    }

    func finish(_ result: Result<String, Error>) {
        timeout?.cancel()
        timeout = nil
        request = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func cancel() {
        finish(.failure(PartyVerificationError(message: "Verification cancelled. Choose Play when you're ready.")))
    }
}

struct VerificationSheet: View {
    let center: VerificationCenter
    let request: VerificationCenter.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A quick check before you join")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: 0xe4f4ff))
            Text("Help keep bots out of Puffer Party. You can keep playing after this check.")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: 0xe4f4ff).opacity(0.85))
            TurnstileView(siteKey: request.siteKey, guestId: request.guestId) { result in
                center.finish(result)
            }
            .frame(height: 90)
            Button("Cancel") { center.cancel() }
                .buttonStyle(QuietButtonStyle(color: Palette.foam))
        }
        .padding(24)
        .background(Color(hex: 0x071b2d).ignoresSafeArea())
        .presentationDetents([.height(300)])
        .interactiveDismissDisabled()
    }
}

/// Renders the Turnstile widget in a web view whose origin is krillion.io,
/// the hostname the site key is registered for.
struct TurnstileView: UIViewRepresentable {
    let siteKey: String
    let guestId: String
    var onResult: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "turnstile")
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString(html, baseURL: Party.site.appendingPathComponent("party"))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onResult = onResult
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
    }

    private var html: String {
        func js(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;background:transparent;}#w{display:flex;justify-content:center;}</style>
        <script>
        function post(m){window.webkit.messageHandlers.turnstile.postMessage(m);}
        function go(){
          try {
            turnstile.render('#w',{
              sitekey:\(js(siteKey)), action:'puffer_join', cData:\(js(guestId)),
              theme:'dark', size:'flexible',
              callback:function(t){post({token:t});},
              'error-callback':function(){post({error:'Verification failed to load. Please try again.'});return true;},
              'expired-callback':function(){post({error:'Verification expired. Please try again.'});}
            });
          } catch(e) { post({error:"Verification couldn't start. Please try again."}); }
        }
        </script>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer onload="go()"
          onerror="post({error:'Verification couldn\\'t load. Please try again.'})"></script>
        </head><body><div id="w"></div></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onResult: (Result<String, Error>) -> Void

        init(onResult: @escaping (Result<String, Error>) -> Void) {
            self.onResult = onResult
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let token = body["token"] as? String {
                onResult(.success(token))
            } else if let error = body["error"] as? String {
                onResult(.failure(PartyVerificationError(message: error)))
            }
        }
    }
}
