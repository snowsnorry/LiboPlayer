import Foundation
import WebKit

struct Catalog: Decodable {
    let account: String?
    let shows: [Show]
    let subscriptions: [String: String]
    let played: [String]
    let paid, guide: Bool
}

enum LibraryError: LocalizedError {
    case unavailable, expired, noAudio, locked
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Couldn’t load Libo/Libo. Check your connection and try again.")
        case .expired: String(localized: "Sign in with Telegram to confirm your account.")
        case .noAudio: String(localized: "Audio is currently unavailable for this episode.")
        case .locked: String(localized: "This episode requires a Libo/Libo subscription.")
        }
    }
}

/// Authenticated operations run in the official site's session. Swift receives only app data.
@MainActor
final class StudioSession: NSObject, WKNavigationDelegate {
    private let page = WKWebView(frame: .zero)
    private var navigationError: Error?
    private var loaded = false
    private var paid = false
    private var guide = false

    func catalog() async throws -> Catalog {
        page.navigationDelegate = self
        page.load(URLRequest(url: StudioSite.home, cachePolicy: .reloadIgnoringLocalCacheData))
        let deadline = ContinuousClock.now + .seconds(40)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let navigationError { throw navigationError }
            if loaded, StudioSite.isPlayer(page.url),
               try await page.evaluateJavaScript("typeof window.pageData?.feeds === 'function'") as? Bool == true {
                let snapshot: Catalog = try await json("""
                    const options = {params: {_t: Date.now()}, timeout: 15000};
                    const {data: {user}} = await axios.get('/api/profile', options);
                    const subs = (await axios.get('/api/subscriptions', options)).data;
                    const shows = pageData.feeds().map(f => ({
                        id: f.id, name: f.name, artwork: f.pic_500() || f.pic_200() || f.image || null
                    }));
                    return JSON.stringify({
                        account: user.tgId ? String(user.tgId) : null, shows,
                        subscriptions: Object.fromEntries(subs.filter(s => s.active).map(s => [s.feed, s.id])),
                        paid: Boolean(user.paid), guide: Boolean(user.guide),
                        played: Array.isArray(user.played) ? user.played.filter(x => typeof x === "string") : Object.keys(user.played || {}).filter(k => user.played[k])
                    });
                    """)
                paid = snapshot.paid
                guide = snapshot.guide
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LibraryError.unavailable
    }

    func episodes(for show: Show) async throws -> [Episode] {
        try await episodeRows("""
            const rows = (await axios.get('/api/episodes/' + encodeURIComponent(showID), {timeout: 20000})).data;
            """, arguments: ["showID": show.id])
    }

    func searchEpisodes(_ term: String) async throws -> [Episode] {
        try await episodeRows("""
            const {data} = await axios.get('/api/suggest', {params: {name: term}, timeout: 15000});
            const rows = [...data.items, ...data.items2];
            """, arguments: ["term": term, "showID": NSNull()])
    }

    private func episodeRows(_ request: String, arguments: [String: Any]) async throws -> [Episode] {
        var parameters = arguments
        parameters["paid"] = paid
        parameters["guide"] = guide
        parameters["untitled"] = String(localized: "Untitled Episode")
        return try await json(request + """

            const seen = new Set();
            const episodes = [];
            for (const e of rows) {
                const feed = showID || e.feed;
                if (!e.id || !feed || e.active === false || seen.has(e.id)) continue;
                seen.add(e.id);
                const locked = Boolean(e.paid && !(e.audioguide ? guide : paid));
                episodes.push({
                    id: e.id, showID: feed, name: e.name || untitled,
                    published: Number(e.createdAt?._seconds || 0) + Number(e.createdAt?._nanoseconds || 0)/1e9,
                    duration: Number(e.length) || 0, locked, played: Boolean(e.played),
                    artwork: e.pic_500 || e.pic_200 || e.pic || null,
                    track: locked ? null : e.track || null
                });
            }
            return JSON.stringify(episodes);
            """, parameters)
    }

    func stream(for episode: Episode) async throws -> URL {
        guard !episode.locked else { throw LibraryError.locked }
        if let url = episode.streamURL { return url }
        let track: String? = try await json("""
            const e = (await axios.get('/api/items/' + encodeURIComponent(id), {timeout: 15000})).data;
            const accessible = !e.paid || (e.audioguide ? guide : paid);
            return JSON.stringify(accessible ? e.track || null : null);
            """, ["id": episode.id, "paid": paid, "guide": guide])
        guard let track, let url = URL(string: track), url.scheme == "https" else { throw LibraryError.noAudio }
        return url
    }

    func setPlayed(_ played: Bool, id: String) async throws {
        let _: Bool = try await json("""
            const options = {timeout: 15000};
            const response = played
                ? await axios.post('/api/played', {item: id}, options)
                : await axios.delete('/api/played/' + encodeURIComponent(id), options);
            // An expired session can redirect to an HTML sign-in page with HTTP 200.
            if (typeof response.data === 'string' && response.data.trimStart().startsWith('<')) {
                throw Error('Sign-in required');
            }
            return JSON.stringify(true);
            """, ["played": played, "id": id])
    }

    func setFollow(_ following: Bool, show: Show) async throws -> [String: String] {
        try await json("""
            const read = async () => {
                const result = await axios.get('/api/subscriptions', {params: {_t: crypto.randomUUID()}, timeout: 15000});
                return Object.fromEntries(result.data.filter(s => s.active).map(s => [s.feed, s.id]));
            };
            const before = await read();
            if (Boolean(before[showID]) === following) return JSON.stringify(before);
            if (following) await axios.post('/api/subscriptions', {feed: showID}, {timeout: 15000});
            else await axios.delete('/api/subscriptions/' + encodeURIComponent(before[showID]), {timeout: 15000});
            const after = await read();
            if (Boolean(after[showID]) !== following) throw Error('Subscription not confirmed');
            return JSON.stringify(after);
            """, ["following": following, "showID": show.id])
    }

    private func json<T: Decodable>(_ script: String, _ arguments: [String: Any] = [:]) async throws -> T {
        guard StudioSite.isPlayer(page.url) else { throw LibraryError.expired }
        let guardOrigin = "if (location.origin !== 'https://play.libolibo.me') throw Error('Unexpected origin');"
        let value = try await page.callAsyncJavaScript(guardOrigin + script, arguments: arguments,
                                                       in: nil, contentWorld: .page)
        guard let string = value as? String else { throw LibraryError.unavailable }
        return try JSONDecoder().decode(T.self, from: Data(string.utf8))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && !StudioSite.isPlayer(action.request.url) ? .cancel : .allow)
    }
}
