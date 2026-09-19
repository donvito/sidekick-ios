import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(AgentRunner.self) private var runner
    @Query(sort: \WorkTask.updatedAt, order: .reverse) private var tasks: [WorkTask]

    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var selectedAction: QuickAction?

    private var recent: [WorkTask] { Array(tasks.prefix(4)) }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    composerCard
                    quickActions
                    if !recent.isEmpty { recentSection }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Sidekick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !settings.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { router.tab = .settings } label: {
                            Label("Set up", systemImage: "key.fill")
                        }
                    }
                }
            }
            .navigationDestination(for: WorkTask.self) { task in
                TaskDetailView(task: task)
            }
            .sheet(item: $selectedAction) { action in
                QuickActionSheet(action: action) { prompt in
                    selectedAction = nil
                    start(prompt: prompt, category: action.category)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.bold())
            Text("Tell me what you need done. I can research, plan, create files, and handle your schedule.")
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return settings.userName.isEmpty ? part : "\(part), \(settings.userName)"
    }

    private var composerCard: some View {
        VStack(spacing: 10) {
            Composer(text: $text, attachments: $attachments, canSend: settings.isConfigured) {
                start(prompt: text, category: "General")
            }
            if !settings.isConfigured {
                Button { router.tab = .settings } label: {
                    Label("Add your API key in Settings to get started", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What I can do")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(QuickAction.all) { action in
                    Button { selectedAction = action } label: {
                        QuickActionCard(action: action)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("See all") { router.tab = .tasks }
                    .font(.subheadline)
            }
            VStack(spacing: 0) {
                ForEach(recent) { task in
                    NavigationLink(value: task) {
                        TaskRow(task: task, showsChevron: true)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    if task.id != recent.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func start(prompt: String, category: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let task = WorkTask(title: "New task", category: category)
        modelContext.insert(task)
        runner.send(trimmed, attachments: attachments, to: task, context: modelContext)
        text = ""
        attachments = []
        router.homePath = [task]
    }
}

struct QuickActionCard: View {
    let action: QuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: action.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(action.color.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.subheadline.weight(.semibold))
                Text(action.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct QuickActionSheet: View {
    let action: QuickAction
    let onStart: (String) -> Void
    @State private var text: String = ""
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Describe what you need…", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                Button {
                    onStart(text)
                } label: {
                    Label("Start task", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!settings.isConfigured || text.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Try one of these").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(action.suggestions, id: \.self) { suggestion in
                    Button { onStart(suggestion) } label: {
                        HStack {
                            Text(suggestion).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(!settings.isConfigured)
                }
                Spacer()
            }
            .padding()
            .background(Theme.background)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { text = action.prompt }
        }
    }
}

struct TaskRow: View {
    let task: WorkTask
    var showsChevron = false
    @Environment(AgentRunner.self) private var runner

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(task.category)
                    Text("·")
                    Text(task.updatedAt, format: .relative(presentation: .named))
                    if !task.artifacts.isEmpty {
                        Text("·")
                        Label("\(task.artifacts.count)", systemImage: "paperclip")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            ProgressView().controlSize(.small)
        case .waitingApproval:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
