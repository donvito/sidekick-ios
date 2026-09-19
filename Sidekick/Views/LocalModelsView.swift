import SwiftUI

/// Settings section for the offline provider: pick, download, import and delete on-device models.
struct LocalModelsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocalModelStore.self) private var store
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        @Bindable var settings = settings
        Section {
            if store.installed.isEmpty {
                Label("No model installed yet. Download one below to chat offline.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            ForEach(store.installed) { model in
                Button {
                    settings.localModelId = model.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).foregroundStyle(.primary)
                            Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.localModelId == model.id {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { store.delete(model) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            engineStatus
        } header: {
            Text("Installed models")
        } footer: {
            Text("Swipe a model to delete it. Chats never leave your device; only the one-time download needs internet.")
        }

        Section {
            ForEach(LocalModelCatalogEntry.all) { entry in
                CatalogRow(entry: entry)
            }
            Button {
                showImporter = true
            } label: {
                Label("Import a .litertlm file…", systemImage: "folder")
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Get a model")
        } footer: {
            Text("Gemma models are published by Google for LiteRT‑LM. Use Import for other .litertlm files, e.g. Gemma 3n E2B/E4B downloaded from Hugging Face after accepting Google's license. Models are stored in the app and excluded from iCloud backups.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            importError = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { try store.importModel(from: url) } catch { importError = error.localizedDescription }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch LocalLLMEngine.shared.state {
        case .idle:
            EmptyView()
        case .loading(let name):
            HStack(spacing: 8) { ProgressView(); Text("Loading \(name)…") }.font(.caption).foregroundStyle(.secondary)
        case .ready(let name):
            Label("\(name) is loaded and ready", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }
}

private struct CatalogRow: View {
    @Environment(LocalModelStore.self) private var store
    let entry: LocalModelCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.body.weight(.medium))
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    Text(entry.sizeLabel).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            if let download = store.downloads[entry.id] {
                ProgressView(value: download.progress)
                Text("\(ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = store.errors[entry.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var action: some View {
        if store.isInstalled(entry) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.green).font(.title3)
        } else if store.downloads[entry.id] != nil {
            Button { store.cancelDownload(entry) } label: {
                Image(systemName: "pause.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
        } else {
            Button { store.download(entry) } label: {
                Text(store.errors[entry.id] == nil ? "Download" : "Resume").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

/// Compact picker used during onboarding: shows the two Gemma options and download state.
struct LocalModelOnboardingPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocalModelStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chats run privately on your iPhone — no account or internet needed after a one-time model download.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(LocalModelCatalogEntry.all) { entry in
                CatalogRow(entry: entry)
                    .padding(12)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            if !store.installed.isEmpty {
                Text("You can switch models later in Settings.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
