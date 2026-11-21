import CryptoKit
import Foundation
import Observation
import WatchConnectivity

/// Only the paired account and bookmarks travel across this link. Audio and catalog requests stay local.
@MainActor @Observable
final class CompanionSync: NSObject, WCSessionDelegate {
    private let library: PodcastLibrary
    private let session: WCSession?
    private(set) var lastReceived: Date?
    private(set) var issue: String?

    init(library: PodcastLibrary) {
        self.library = library
        session = WCSession.isSupported() ? .default : nil
        super.init()
        library.companionStateChanged = { [weak self] in self?.publish() }
        session?.delegate = self
        session?.activate()
    }

    #if os(watchOS)
    enum SyncStatus {
        case idle, contacting, waiting, unlockPhone, installPhoneApp, signIn, complete, failed
    }
    private(set) var status = SyncStatus.idle
    private var requestID: UUID?

    func synchronize() {
        guard status != .contacting else { return }
        guard let session else { status = .failed; return }
        issue = nil
        requestID = UUID()
        guard session.activationState == .activated else {
            status = .waiting
            session.activate()
            return
        }
        publish()
        requestPhoneState()
    }

    private func requestPhoneState() {
        guard let session, let id = requestID, status != .contacting else { return }
        status = .contacting
        session.sendMessage(["resend": true], replyHandler: { reply in
            Task { @MainActor in
                guard self.requestID == id else { return }
                self.receiveContext(reply)
                if self.requestID == id { self.status = .failed }
            }
        }, errorHandler: { error in
            Task { @MainActor in
                guard self.requestID == id else { return }
                switch (error as? WCError)?.code {
                case .companionAppNotInstalled: self.status = .installPhoneApp
                case .notReachable:
                    self.status = session.iOSDeviceNeedsUnlockAfterRebootForReachability ? .unlockPhone : .waiting
                default:
                    self.status = .failed
                }
            }
        })
    }
    #endif

    private func publish(replyTo request: String? = nil) {
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        do {
            var context = try makeContext(for: session)
            #if os(watchOS)
            context["syncRequest"] = requestID?.uuidString
            #else
            // Changing the acknowledgement also delivers a reply when account data is unchanged.
            context["syncReply"] = request
            #endif
            try session.updateApplicationContext(context)
            issue = nil
        } catch { issue = String(localized: "Couldn’t sync bookmarks. Try again.") }
    }

    private func makeContext(for session: WCSession) throws -> [String: Any] {
        let snapshot = library.collection.bookmarkSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        var context: [String: Any] = ["schema": 1]
        #if os(iOS)
        if let credential = try StudioCredential.saved(), credential.accountID == snapshot.account {
            context["credential"] = try encoder.encode(credential)
        }
        #endif
        // Application context is latest-state delivery. Large libraries use a queued file.
        if data.count < 40_000 {
            context["bookmarks"] = data
        } else {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            context["file"] = digest
            if !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["bookmarks"] as? String == digest }) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-" + UUID().uuidString)
                try data.write(to: url, options: .atomic)
                session.transferFile(url, metadata: ["bookmarks": digest])
            }
        }
        return context
    }

    private func receiveContext(_ context: [String: Any], fresh: Bool = true) {
        guard context["schema"] as? Int == 1 else { return }
        do {
            #if os(watchOS)
            let credential = try (context["credential"] as? Data).map { try JSONDecoder().decode(StudioCredential.self, from: $0) }
            if let credential { try library.adoptPhoneCredential(credential) }
            #endif
            if let bookmarks = context["bookmarks"] as? Data { try merge(bookmarks) }
            #if os(watchOS)
            if fresh, requestID != nil, let credential {
                requestID = nil
                status = credential.signedIn && library.account != nil ? .complete : .signIn
            }
            #endif
        } catch { issue = String(localized: "Couldn’t sync your library. Try again.") }
    }

    private func merge(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(EpisodeCollection.BookmarkSnapshot.self, from: data)
        // A transfer may finish before the corresponding account context, or after a switch.
        let active = snapshot.account == library.account
        let shelf = active ? library.collection : EpisodeCollection(account: snapshot.account)
        try shelf.mergeBookmarks(snapshot) { episode in
            if active && library.session.isAvailable { return library.session.withCurrentAccess(episode) }
            return episode
        }
        if active { lastReceived = Date() }
        issue = nil
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard activationState == .activated else {
                #if os(watchOS)
                if self.requestID != nil { self.requestID = nil; self.status = .failed }
                #endif
                return
            }
            let context = session.receivedApplicationContext
            self.receiveContext(context, fresh: false)
            self.publish(replyTo: context["syncRequest"] as? String)
            #if os(watchOS)
            self.requestPhoneState()
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.receiveContext(applicationContext)
            #if os(iOS)
            if let request = applicationContext["syncRequest"] as? String { self.publish(replyTo: request) }
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["resend"] as? Bool == true { Task { @MainActor in self.publish() } }
    }

    #if os(iOS)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            guard message["resend"] as? Bool == true else { replyHandler([:]); return }
            replyHandler((try? self.makeContext(for: session)) ?? [:])
        }
    }
    #else
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { Task { @MainActor in self.requestPhoneState() } }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.requestPhoneState() }
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["bookmarks"] != nil else { return }
        // Watch Connectivity removes the received file as soon as this delegate returns.
        let data = Result { try Data(contentsOf: file.fileURL) }
        Task { @MainActor in
            do { try self.merge(data.get()) }
            catch { self.issue = String(localized: "Couldn’t sync bookmarks. Try again.") }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?["bookmarks"] != nil else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if error != nil { Task { @MainActor in self.issue = String(localized: "Couldn’t sync bookmarks. Try again.") } }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.publish() } }
    #endif
}
