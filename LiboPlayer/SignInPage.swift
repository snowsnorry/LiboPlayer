import SwiftUI
import WebKit

struct SignInPage: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var controller = LoginController()
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var guestToConfirm: StudioCredential?

    var body: some View {
        NavigationStack {
            LoginView(controller: controller)
                .ignoresSafeArea(edges: .bottom)
                .leadingTitle(Text("Libo/Libo Account"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() }
                        else { Button("Done") { Task { await finish() } } }
                    }
                }
        }
        .interactiveDismissDisabled(saving)
        .alert("Libo/Libo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Close", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Continue as a guest?", isPresented: Binding(
            get: { guestToConfirm != nil }, set: { if !$0 { guestToConfirm = nil } }
        ), presenting: guestToConfirm) { guest in
            Button("Continue as a guest") { Task { await finish(confirmedGuest: guest) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func finish(confirmedGuest: StudioCredential? = nil) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let credential: StudioCredential
            if let confirmedGuest { credential = confirmedGuest }
            else {
                credential = try await controller.credential()
                if !credential.signedIn, try StudioCredential.saved()?.signedIn == true {
                    guestToConfirm = credential
                    return
                }
            }
            try await library.useCredential(credential)
            dismiss()
        } catch { errorMessage = LibraryError.message(for: error) }
    }

    static func hasPreviousLoginStorage() async -> Bool {
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
        return records.contains { $0.displayName == "libolibo.me" || $0.displayName == StudioSite.home.host }
    }
}

private struct LoginView: UIViewControllerRepresentable {
    let controller: LoginController
    func makeUIViewController(context: Context) -> LoginController { controller }
    func updateUIViewController(_ uiViewController: LoginController, context: Context) {}
}

@MainActor
final class LoginController: UIViewController, WKUIDelegate, WKNavigationDelegate {
    private var windows: [WKWebView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        let main = attach(configuration: WKWebViewConfiguration())
        main.load(URLRequest(url: StudioSite.home.appending(queryItems: [URLQueryItem(name: "start", value: "profile")])))
    }

    func credential() async throws -> StudioCredential {
        guard let web = windows.first, windows.count == 1, StudioSite.isPlayer(web.url) else { throw LibraryError.expired }
        // Only the visible studio account page can hand off its own session after Done.
        let result = try await web.evaluateJavaScript("""
            (() => {
                if (location.origin !== 'https://play.libolibo.me' || typeof window.pageData?.feeds !== 'function') return null;
                return {token: localStorage.liboToken, signedIn: localStorage.webAuthed === 'true' || !!localStorage.mailAuth};
            })()
            """)
        guard let values = result as? [String: Any], let token = values["token"] as? String, !token.isEmpty,
              let signedIn = values["signedIn"] as? Bool else { throw LibraryError.unavailable }
        return StudioCredential(token: token, signedIn: signedIn)
    }

    private func attach(configuration: WKWebViewConfiguration) -> WKWebView {
        let web = WKWebView(frame: view.bounds, configuration: configuration)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.uiDelegate = self
        web.navigationDelegate = self
        windows.append(web)
        view.addSubview(web)
        return web
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit supplies the configuration that connects the Telegram popup to its opener.
        attach(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard windows.first !== webView else { return }
        windows.removeAll { $0 === webView }
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "tg" || (url.scheme == "https" && url.host == "t.me" && action.navigationType == .linkActivated) {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            let allowed = StudioSite.isPlayer(url) || (url.scheme == "https" && url.host == "oauth.telegram.org")
                || url.absoluteString == "about:blank"
            decisionHandler(allowed ? .allow : .cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
