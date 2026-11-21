import ImageIO
import SwiftUI
import UIKit

actor WatchArtwork {
    static let shared = WatchArtwork()
    private let cache = NSCache<NSURL, UIImage>()
    private var pending = [URL: Task<UIImage?, Never>]()

    private init() { cache.totalCostLimit = 4 * 1024 * 1024 }

    // Watch ImageIO cannot decode the studio's WebP thumbnails, including URLs in iPhone bookmarks.
    static func address(_ candidates: String?...) -> String? {
        candidates.compactMap { $0 }.first { value in
            guard let url = URL(string: value), url.host != nil else { return false }
            return url.pathExtension.lowercased() != "webp"
        }
    }

    func image(at url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = pending[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 256]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let image = UIImage(cgImage: thumb)
            cache.setObject(image, forKey: url as NSURL, cost: thumb.bytesPerRow * thumb.height)
            return image
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        return result
    }
}

struct WatchArtworkImage<Placeholder: View>: View {
    let address: String?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        let url = address.flatMap(URL.init(string:))
        Group {
            if let loaded, loaded.url == url { Image(uiImage: loaded.image).resizable().scaledToFill() }
            else { placeholder() }
        }
        .task(id: url) {
            guard let url, let image = await WatchArtwork.shared.image(at: url), !Task.isCancelled else { return }
            loaded = (url, image)
        }
    }
}
