import SwiftUI
import UIKit

struct EpisodeDetails: View {
    @Environment(PodcastLibrary.self) private var library
    let episode: Episode
    let source: QueueSource
    @State private var summary: String?
    @State private var loadingDescription = false

    var body: some View {
        let show = library.show(for: episode)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Cover(artwork: episode.artwork ?? show?.artwork, radius: 14)
                    .frame(width: 168)
                VStack(alignment: .leading, spacing: 6) {
                    if let show { Text(show.name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
                    Text(episode.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if episode.published > 0 {
                        Text(Date(timeIntervalSince1970: episode.published), format: .dateTime.day().month(.wide).year())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                EpisodePlaybackButton(episode: episode, source: source)
                if let summary {
                    Divider()
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if loadingDescription {
                    ProgressView("Loading description…").font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .leadingTitle(Text("Episode"))
        .task(id: episode.id) { await loadDescription() }
    }

    private func loadDescription() async {
        let archived = library.episodes[episode.showID]?.first { $0.id == episode.id }
        if let description = episode.description ?? archived?.description,
           let text = Self.readableDescription(description) {
            summary = text
            return
        }

        loadingDescription = true
        defer { loadingDescription = false }
        let owner = library.account
        guard let session = try? await library.sessionForRequest(), !Task.isCancelled,
              owner == library.account,
              let description = try? await session.episodeDescription(episode.id),
              !Task.isCancelled, session === library.session else { return }
        summary = Self.readableDescription(description)
    }

    private static func readableDescription(_ description: String) -> String? {
        let htmlPattern = #"</?[a-zA-Z][^>]*>|&(?:[a-zA-Z]+|#\w+);"#
        guard description.range(of: htmlPattern, options: .regularExpression) != nil else { return description }
        // Keep paragraph and list structure, but remove tags and attributes that could load resources.
        let markup = description
            .replacingOccurrences(of: #"(?i)<(?!/?(?:p|br|div|li|ul|ol)\b)[^>]*>"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(/?(?:p|br|div|li|ul|ol))\b[^>]*>"#,
                                  with: "<$1>", options: .regularExpression)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let text = try? NSAttributedString(data: Data(markup.utf8), options: options, documentAttributes: nil)
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
