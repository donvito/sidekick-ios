import SwiftUI
import SwiftData
import QuickLook
import AVKit

struct LibraryView: View {
    @Query(sort: \Artifact.createdAt, order: .reverse) private var artifacts: [Artifact]
    @Environment(\.modelContext) private var modelContext
    @State private var filter: ArtifactKind?
    @State private var selected: Artifact?

    private var filtered: [Artifact] {
        filter.map { k in artifacts.filter { $0.kind == k } } ?? artifacts
    }

    var body: some View {
        NavigationStack {
            Group {
                if artifacts.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "folder", description: Text("Files, images, videos and email drafts Sidekick creates for you will show up here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            filterBar
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(filtered) { artifact in
                                    Button { selected = artifact } label: { ArtifactTile(artifact: artifact) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { delete(artifact) } label: { Label("Delete", systemImage: "trash") }
                                        }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .sheet(item: $selected) { ArtifactDetailView(artifact: $0) }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", selected: filter == nil) { filter = nil }
                ForEach(ArtifactKind.allCases, id: \.self) { kind in
                    FilterChip(title: kind.label, selected: filter == kind) { filter = kind }
                }
            }
        }
    }

    private func delete(_ artifact: Artifact) {
        try? FileManager.default.removeItem(at: artifact.url)
        modelContext.delete(artifact)
        try? modelContext.save()
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.cardBackground, in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct ArtifactTile: View {
    let artifact: Artifact
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.1))
                if artifact.kind == .image, let img = UIImage(contentsOfFile: artifact.url.path) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: artifact.kind.systemImage).font(.largeTitle).foregroundStyle(Theme.accent)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(artifact.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(artifact.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ArtifactCard: View {
    let artifact: Artifact
    var body: some View {
        HStack(spacing: 12) {
            if artifact.kind == .image, let img = UIImage(contentsOfFile: artifact.url.path) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: artifact.kind.systemImage)
                    .font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(artifact.kind == .email ? "Email draft · tap to open in Mail" : artifact.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ArtifactDetailView: View {
    let artifact: Artifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch artifact.kind {
                case .email: EmailDraftView(artifact: artifact)
                case .video: VideoPlayer(player: AVPlayer(url: artifact.url))
                default: QuickLookPreview(url: artifact.url)
                }
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if artifact.kind != .email {
                    ToolbarItem(placement: .topBarTrailing) { ShareLink(item: artifact.url) }
                }
            }
        }
    }
}

struct EmailDraftView: View {
    let artifact: Artifact
    private var draft: EmailDraft? {
        (try? Data(contentsOf: artifact.url)).flatMap { try? JSONDecoder().decode(EmailDraft.self, from: $0) }
    }

    var body: some View {
        if let draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("To", value: draft.to.isEmpty ? "—" : draft.to)
                    LabeledContent("Subject", value: draft.subject)
                    Divider()
                    Text(draft.body).textSelection(.enabled)
                    Button {
                        if let url = mailtoURL(draft) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Open in Mail", systemImage: "envelope").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        UIPasteboard.general.string = "Subject: \(draft.subject)\n\n\(draft.body)"
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Could not read draft", systemImage: "envelope.badge")
        }
    }

    private func mailtoURL(_ draft: EmailDraft) -> URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = draft.to
        comps.queryItems = [URLQueryItem(name: "subject", value: draft.subject), URLQueryItem(name: "body", value: draft.body)]
        return comps.url
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
