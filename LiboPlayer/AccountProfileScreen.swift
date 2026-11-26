import SwiftUI

struct AccountPanelHeader: View {
    let title: LocalizedStringKey
    var closeDisabled = false
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.subheadline.bold())
                    .frame(width: 30, height: 30).background(.quaternary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
            .disabled(closeDisabled)
        }
    }
}

private struct AccountPanelHeight: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.dynamicTypeSize.isAccessibilitySize ? context.maxDetentValue : min(260, context.maxDetentValue)
    }
}

struct AccountPanel<Content: View>: View {
    var expanded = false
    var closeDisabled = false
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountPanelHeader(title: "Libo/Libo Account", closeDisabled: closeDisabled, close: close)
            content()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents(expanded ? [.large] : [.custom(AccountPanelHeight.self)])
        .presentationDragIndicator(.visible)
    }
}

struct AccountProfileScreen: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var errorMessage: String?

    private var initials: String {
        let words = library.profile?.name?.split(whereSeparator: { $0.isWhitespace }) ?? []
        let initials = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(initials).uppercased()
    }

    var body: some View {
        AccountPanel(close: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(.purple.opacity(0.12))
                            if initials.isEmpty { Image(systemName: "person.fill") }
                            else { Text(verbatim: initials).font(.headline) }
                        }
                        .foregroundStyle(.purple)
                        .frame(width: 54, height: 54)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(library.profile?.name ?? String(localized: "Profile")).font(.headline)
                            if let username = library.profile?.username {
                                Text(verbatim: "@" + username).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    Button { confirmingSignOut = true } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .alert("Sign out?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                do {
                    try library.signOut()
                    dismiss()
                    Task { await library.refresh(quietIfCached: true) }
                } catch { errorMessage = LibraryError.message(for: error) }
            }
        } message: { Text("You’ll continue as a guest.") }
        .alert("Libo/Libo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Close", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
