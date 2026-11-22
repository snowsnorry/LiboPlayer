import SwiftUI
import WebKit

struct SignInPage: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let restoringPreviousLogin: Bool
    @State private var attempt = 0
    @State private var showingTelegram = false
    @State private var saving = false
    @State private var cancelled = false
    @State private var pendingCredential: StudioCredential?
    @State private var errorMessage: String?

    var body: some View {
        AccountPanel(expanded: showingTelegram, closeDisabled: saving, close: { cancelled = true; dismiss() }) {
            if !showingTelegram {
                Text("Sign in to see the shows you follow.")
                    .foregroundStyle(.secondary)
            }
            LoginView(restorePrevious: restoringPreviousLogin && attempt == 0,
                      popupChanged: { showingTelegram = $0 }) { result in
                guard !cancelled, !saving, errorMessage == nil else { return }
                switch result {
                case .success(let credential): finish(using: credential)
                case .failure(let error): errorMessage = LibraryError.message(for: error)
                }
            }
            .id(attempt)
            .disabled(saving)
            .overlay { if saving { ProgressView() } }
        }
        .interactiveDismissDisabled(saving)
        .alert("Libo/Libo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Try Again") {
                if let pendingCredential { finish(using: pendingCredential) }
                else { showingTelegram = false; attempt += 1 }
            }
            Button("Cancel", role: .cancel) { cancelled = true; dismiss() }
        } message: { Text(errorMessage ?? "") }
    }

    private func finish(using credential: StudioCredential) {
        guard !saving, !cancelled else { return }
        saving = true
        pendingCredential = credential
        Task {
            defer { saving = false }
            do {
                try await library.useCredential(credential)
                dismiss()
            } catch {
                if error as? LibraryError == .expired { pendingCredential = nil }
                errorMessage = LibraryError.message(for: error)
            }
        }
    }

    static func hasPreviousLoginStorage() async -> Bool {
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
        return records.contains { $0.displayName == "libolibo.me" || $0.displayName == StudioSite.home.host }
    }
}

private struct LoginView: UIViewControllerRepresentable {
    let restorePrevious: Bool
    let popupChanged: (Bool) -> Void
    let onResult: (Result<StudioCredential, Error>) -> Void

    func makeUIViewController(context: Context) -> LoginController {
        let controller = LoginController()
        controller.popupChanged = popupChanged
        controller.restorePrevious = restorePrevious
        controller.onResult = onResult
        return controller
    }
    func updateUIViewController(_ controller: LoginController, context: Context) {}
    static func dismantleUIViewController(_ controller: LoginController, coordinator: ()) {
        controller.stop()
    }
}

@MainActor
private final class LoginController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    fileprivate var popupChanged: ((Bool) -> Void)?
    fileprivate var restorePrevious = false
    fileprivate var onResult: ((Result<StudioCredential, Error>) -> Void)?
    private var windows: [WKWebView] = []
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = restorePrevious ? .default() : .nonPersistent()
        configuration.userContentController.add(self, name: "studioLogin")
        let main = attach(configuration: configuration)
        main.isHidden = true
        main.isOpaque = false
        main.backgroundColor = .clear
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)
        spinner.startAnimating()
        var request = URLRequest(url: StudioSite.home.appending(queryItems: [URLQueryItem(name: "start", value: "profile")]))
        request.timeoutInterval = 30
        main.load(request)
    }

    func stop() {
        onResult = nil
        popupChanged = nil
        windows.first?.configuration.userContentController.removeScriptMessageHandler(forName: "studioLogin")
        for web in windows {
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.stopLoading()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === windows.first else { return }
        webView.isHidden = true
        spinner.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === windows.first, StudioSite.isPlayer(webView.url) else { return }
        let restore = restorePrevious
        restorePrevious = false
        webView.callAsyncJavaScript(Self.prepareWidget, arguments: ["restore": restore], in: nil, in: .page) { [weak self] result in
            guard let self, self.onResult != nil else { return }
            self.spinner.stopAnimating()
            switch result {
            case .success(let value):
                if let token = value as? String, !token.isEmpty {
                    self.onResult?(.success(StudioCredential(token: token, signedIn: true)))
                } else { webView.isHidden = webView !== self.windows.last }
            case .failure(let error): self.onResult?(.failure(error))
            }
        }
    }

    // Use the studio's own widget and exchange. An existing guest or member token in
    // localStorage is not evidence that a new sign-in succeeded.
    private static let prepareWidget = """
        if (location.origin !== 'https://play.libolibo.me') throw Error('Unexpected origin');
        if (restore && (localStorage.webAuthed === 'true' || localStorage.mailAuth) && localStorage.liboToken)
            return localStorage.liboToken;

        const bridge = window.webkit.messageHandlers.studioLogin;
        const isExchange = config => config?.method?.toLowerCase() === 'post'
            && new URL(config.url, location.href).href === location.origin + '/webAuth';
        axios.interceptors.response.use(response => {
            if (isExchange(response.config)) bridge.postMessage(response.data?.token || '');
            return response;
        }, error => {
            if (isExchange(error.config)) bridge.postMessage('');
            return Promise.reject(error);
        });

        const box = document.createElement('div');
        box.id = 'libo-player-login';
        const style = document.createElement('style');
        style.textContent = `
            html, body { background: transparent !important; overflow: hidden !important; }
            body > :not(#libo-player-login) { display: none !important; }
            #libo-player-login iframe { border-radius: 10px; }
            #libo-player-login { position: fixed; inset: 0; display: grid; place-items: center; }
        `;
        document.head.append(style);
        document.body.append(box);
        await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(Error('Widget unavailable')), 15000);
            box.addEventListener('load', event => {
                const frame = event.target;
                if (frame instanceof HTMLIFrameElement && new URL(frame.src).origin === 'https://oauth.telegram.org') {
                    clearTimeout(timer);
                    resolve();
                }
            }, true);
            window.renderTelegramWidget(box.id, 'onTgWebAuth');
        });
        return null;
        """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.webView === windows.first, message.frameInfo.isMainFrame,
              origin.protocol == "https", origin.host == StudioSite.home.host, [0, 443].contains(origin.port),
              StudioSite.isPlayer(message.webView?.url), let token = message.body as? String else { return }
        if token.isEmpty { onResult?(.failure(LibraryError.unavailable)) }
        else { onResult?(.success(StudioCredential(token: token, signedIn: true))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onResult?(.failure(error)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onResult?(.failure(error)) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onResult?(.failure(LibraryError.unavailable))
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
        windows.last?.isHidden = true
        let popup = attach(configuration: configuration)
        popupChanged?(true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard windows.first !== webView else { return }
        windows.removeAll { $0 === webView }
        webView.removeFromSuperview()
        windows.last?.isHidden = false
        popupChanged?(windows.count > 1)
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
