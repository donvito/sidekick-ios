import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Bindable var task: WorkTask
    @Environment(\.modelContext) private var modelContext
    @Environment(AgentRunner.self) private var runner
    @Environment(AppSettings.self) private var settings

    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var previewArtifact: Artifact?

    private var isRunning: Bool { runner.isRunning(task) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let messages = task.sortedMessages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageView(message: message, artifacts: artifacts(after: message, next: index + 1 < messages.count ? messages[index + 1] : nil), onOpenArtifact: { previewArtifact = $0 })
                    }
                    if let approval = runner.approval(for: task) {
                        ApprovalCard(approval: approval)
                    }
                    if isRunning && runner.approval(for: task) == nil {
                        WorkingIndicator()
                    }
                    if let error = task.lastError {
                        Label(error, systemImage: task.status == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.footnote)
                            .foregroundStyle(task.status == .failed ? .red : .secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((task.status == .failed ? Color.red : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .background(Theme.background)
            .onChange(of: task.updatedAt) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: task.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = transcriptText } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                    if !task.artifacts.isEmpty {
                        Section("Deliverables") {
                            ForEach(task.artifacts.sorted { $0.createdAt < $1.createdAt }) { artifact in
                                Button { previewArtifact = artifact } label: { Label(artifact.title, systemImage: artifact.kind.systemImage) }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(text: $text, attachments: $attachments, placeholder: "Follow up or give more detail…", isRunning: isRunning, canSend: settings.isConfigured && !isRunning) {
                runner.send(text, attachments: attachments, to: task, context: modelContext)
                text = ""
                attachments = []
            } onStop: {
                runner.cancel(task)
            }
            .padding(12)
            .background(.bar)
        }
        .sheet(item: $previewArtifact) { artifact in
            ArtifactDetailView(artifact: artifact)
        }
    }

    private func artifacts(after message: ChatMessage, next: ChatMessage?) -> [Artifact] {
        guard message.role == .assistant else { return [] }
        return task.artifacts
            .filter { $0.createdAt >= message.createdAt && (next == nil || $0.createdAt < next!.createdAt) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var transcriptText: String {
        task.sortedMessages.map { m in
            "\(m.role == .user ? "You" : "Sidekick"): \(m.content)"
        }.joined(separator: "\n\n")
    }
}

struct MessageView: View {
    let message: ChatMessage
    let artifacts: [Artifact]
    let onOpenArtifact: (Artifact) -> Void

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { att in
                            if att.isImage, let img = UIImage(contentsOfFile: att.url.path) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Label(att.filename, systemImage: "doc.fill").font(.caption).padding(8).background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.sortedSteps) { step in
                    StepRow(step: step)
                }
                if !message.content.isEmpty {
                    MarkdownText(message.content)
                        .textSelection(.enabled)
                }
                ForEach(artifacts) { artifact in
                    Button { onOpenArtifact(artifact) } label: { ArtifactCard(artifact: artifact) }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StepRow: View {
    let step: ToolStep
    @State private var expanded = false

    private var tool: AgentTool? { ToolRegistry.tool(named: step.toolName) }
    private var summary: String { tool?.summary(for: JSONValue.parse(step.argumentsJSON)) ?? step.toolName }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    icon.frame(width: 18)
                    Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.toolName).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !step.argumentsJSON.isEmpty {
                        Text(JSONValue.parse(step.argumentsJSON).prettyDescription).font(.caption2.monospaced()).lineLimit(12)
                    }
                    if !step.result.isEmpty {
                        Divider()
                        Text(step.result).font(.caption2).lineLimit(14).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.footnote)
        case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.footnote)
        }
    }
}

struct WorkingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ApprovalCard: View {
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sidekick wants to take an action", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(approval.summary).font(.body)
            HStack {
                Button(role: .cancel) { approval.resolve(false) } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { approval.resolve(true) } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.4)))
    }
}

/// Very small markdown renderer: headings, bullets, numbered lists, paragraphs with inline styling.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
    }

    private var blocks: [AnyView] {
        var views: [AnyView] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            views.append(AnyView(Text(inline(joined))))
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { flush(); views.append(AnyView(Text(inline(String(line.dropFirst(4)))).font(.subheadline.weight(.semibold)).padding(.top, 4))) }
            else if line.hasPrefix("## ") { flush(); views.append(AnyView(Text(inline(String(line.dropFirst(3)))).font(.headline).padding(.top, 6))) }
            else if line.hasPrefix("# ") { flush(); views.append(AnyView(Text(inline(String(line.dropFirst(2)))).font(.title3.weight(.bold)).padding(.top, 6))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(inline(String(line.dropFirst(2)))) }.padding(.leading, 4)))
            } else if let match = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                flush()
                let number = String(line[match]).trimmingCharacters(in: .whitespaces)
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) { Text(number).monospacedDigit(); Text(inline(String(line[match.upperBound...]))) }.padding(.leading, 4)))
            } else if line.hasPrefix("```") {
                continue
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return views
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
