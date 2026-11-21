import AVFoundation
import os
import UniformTypeIdentifiers

enum EpisodeAudio {
    /// Returns a validated temporary file. The caller owns its removal or installation.
    static func download(from url: URL, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let files = FileManager.default
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        defer { try? files.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.mimeType != "text/html" else { throw LibraryError.noAudio }
        // A playlist can start playback online without containing any audio on the device.
        let mime = http.mimeType?.lowercased() ?? ""
        guard !mime.contains("mpegurl"), !mime.contains("scpls"),
              !["m3u", "m3u8", "pls"].contains(http.url?.pathExtension.lowercased() ?? "") else {
            throw LibraryError.noAudio
        }
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, http.expectedContentLength < 0 || Int64(bytes) == http.expectedContentLength else {
            throw LibraryError.noAudio
        }

        let type = http.mimeType.flatMap { UTType(mimeType: $0) }
        let pathExtension = (http.url ?? url).pathExtension.lowercased()
        let ext: String
        if let type, type.conforms(to: .audio), let suffix = type.preferredFilenameExtension { ext = suffix }
        else if ["mp3", "m4a", "aac", "wav", "mp4"].contains(pathExtension) { ext = pathExtension }
        else { ext = "mp3" }

        let audio = files.temporaryDirectory.appending(component: UUID().uuidString).appendingPathExtension(ext)
        try files.moveItem(at: temporary, to: audio)
        do {
            guard try await AVURLAsset(url: audio).load(.isPlayable) else { throw LibraryError.noAudio }
            try Task.checkCancellation()
            return audio
        } catch {
            try? files.removeItem(at: audio)
            throw error
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @MainActor @Sendable (Double) -> Void
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(uncheckedState: nil)

    init(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // Async downloads deliver task callbacks and update Progress while writing to disk.
        let token = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak task, onProgress] _, _ in
            guard let task else { return }
            let expected = task.countOfBytesExpectedToReceive
            guard expected > 0 else { return }
            let fraction = Double(task.countOfBytesReceived) / Double(expected)
            Task { @MainActor in onProgress(fraction) }
        }
        observation.withLockUnchecked { $0 = token }
    }
}
