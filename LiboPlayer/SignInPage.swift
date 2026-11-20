import SwiftUI
import WebKit

enum StudioSite {
    static let home = URL(string: "https://play.libolibo.me/")!

    static func isPlayer(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == home.host && (url?.port == nil || url?.port == 443)
    }
}

struct SignInPage: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LoginController { LoginController() }
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
