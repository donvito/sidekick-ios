import SwiftUI
import SwiftData
import EventKit
import HealthKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Query(sort: \MemoryItem.createdAt, order: .reverse) private var memories: [MemoryItem]
    @Environment(\.modelContext) private var modelContext
    @State private var showKey = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $settings.preset) {
                        ForEach(ProviderPreset.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.preset.needsBaseURL {
                        TextField("Base URL (…/v1)", text: $settings.baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    HStack {
                        if showKey {
                            TextField("API key", text: $settings.apiKey)
                        } else {
                            SecureField("API key", text: $settings.apiKey)
                        }
                        Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Chat model (must support tools)", text: $settings.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("AI provider")
                } footer: {
                    Text("Your key is stored in the iOS Keychain and only sent to the provider you choose. Any OpenAI-compatible endpoint works.")
                }

                Section("Media generation") {
                    TextField("Image model", text: $settings.imageModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Video model", text: $settings.videoModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                Section {
                    Toggle("Ask before taking actions", isOn: $settings.askBeforeActing)
                } footer: {
                    Text("When on, Sidekick asks for approval before creating calendar events or reminders.")
                }

                Section("About you") {
                    TextField("Your name", text: $settings.userName)
                    TextField("Anything Sidekick should know (role, goals, preferences)", text: $settings.userAbout, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    if memories.isEmpty {
                        Text("Sidekick will remember facts you share during tasks.").foregroundStyle(.secondary)
                    }
                    ForEach(memories) { memory in
                        Text(memory.text)
                    }
                    .onDelete { offsets in
                        for i in offsets { modelContext.delete(memories[i]) }
                        try? modelContext.save()
                    }
                } header: {
                    Text("Memory")
                }

                Section("Permissions") {
                    PermissionRow(title: "Calendar", granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess)
                    PermissionRow(title: "Reminders", granted: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)
                    PermissionRow(title: "Health", granted: HKHealthStore.isHealthDataAvailable())
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                Section("Capabilities") {
                    ForEach(ToolRegistry.all, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.subheadline.monospaced())
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Available" : "Asked when needed").foregroundStyle(.secondary).font(.subheadline)
        }
    }
}

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        Text("Meet Sidekick").font(.largeTitle.bold())
                        Text("A personal AI assistant that does the work, not just the talking.").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow(icon: "magnifyingglass", color: .blue, title: "Researches the web", detail: "Searches, reads pages and cites sources.")
                        FeatureRow(icon: "calendar", color: .orange, title: "Runs your schedule", detail: "Reads your calendar, books events and reminders — with your approval.")
                        FeatureRow(icon: "doc.richtext", color: .purple, title: "Creates deliverables", detail: "PDFs, spreadsheets, images, videos and email drafts, saved to your Library.")
                        FeatureRow(icon: "heart.text.square", color: .red, title: "Understands your data", detail: "Photos, files and Apple Health — analyzed on request.")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect an AI provider").font(.headline)
                        Picker("Provider", selection: $settings.preset) {
                            ForEach(ProviderPreset.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        if settings.preset.needsBaseURL {
                            TextField("Base URL (…/v1)", text: $settings.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        }
                        SecureField(settings.preset.requiresAPIKey ? "API key" : "API key (optional)", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model", text: $settings.model)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Your name (optional)", text: $settings.userName)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        settings.hasOnboarded = true
                        dismiss()
                    } label: {
                        Text(settings.isConfigured ? "Get started" : "Skip for now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 36, height: 36).background(color.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
