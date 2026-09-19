import Foundation
import SwiftData
import Observation

@MainActor
final class PendingApproval: Identifiable {
    let id = UUID()
    let taskId: UUID
    let step: ToolStep
    let summary: String
    private var continuation: CheckedContinuation<Bool, Never>?

    init(taskId: UUID, step: ToolStep, summary: String) {
        self.taskId = taskId
        self.step = step
        self.summary = summary
    }

    func wait() async -> Bool {
        await withCheckedContinuation { self.continuation = $0 }
    }

    func resolve(_ approved: Bool) {
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

/// Drives the plan → act → observe loop for a task, persisting every step to SwiftData
/// so the UI can render progress live.
@MainActor
@Observable
final class AgentRunner {
    static let shared = AgentRunner()

    private(set) var runningTaskIds: Set<UUID> = []
    private(set) var approvals: [UUID: PendingApproval] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    let maxRounds = 12

    func isRunning(_ task: WorkTask) -> Bool { runningTaskIds.contains(task.id) }
    func approval(for task: WorkTask) -> PendingApproval? { approvals[task.id] }

    func cancel(_ task: WorkTask) {
        jobs[task.id]?.cancel()
        approvals[task.id]?.resolve(false)
    }

    func send(_ text: String, attachments: [PendingAttachment], to task: WorkTask, context: ModelContext) {
        guard !runningTaskIds.contains(task.id) else { return }
        let settings = AppSettings.shared

        let order = (task.messages.map(\.order).max() ?? -1) + 1
        let userMessage = ChatMessage(role: .user, content: text, order: order)
        userMessage.task = task
        context.insert(userMessage)
        for pending in attachments {
            if let path = try? FileStore.write(pending.data, folder: "attachments", filename: pending.filename) {
                let att = Attachment(filename: pending.filename, mimeType: pending.mimeType, relativePath: path, extractedText: pending.extractedText)
                att.message = userMessage
                context.insert(att)
            }
        }
        if task.messages.count <= 1 {
            task.title = Self.deriveTitle(from: text, attachments: attachments)
        }
        task.status = .running
        task.lastError = nil
        task.updatedAt = .now
        try? context.save()

        runningTaskIds.insert(task.id)
        jobs[task.id] = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(task: task, context: context, settings: settings)
            self.runningTaskIds.remove(task.id)
            self.jobs[task.id] = nil
            self.approvals[task.id] = nil
            try? context.save()
        }
    }

    private func runLoop(task: WorkTask, context: ModelContext, settings: AppSettings) async {
        let client = LLMClient(settings: settings)
        let toolContext = ToolContext(task: task, modelContext: context, settings: settings)
        var round = 0
        do {
            while round < maxRounds {
                round += 1
                try Task.checkCancellation()
                let transcript = buildTranscript(task: task, context: context, settings: settings)
                let order = (task.messages.map(\.order).max() ?? -1) + 1
                let assistant = ChatMessage(role: .assistant, content: "", order: order)
                assistant.task = task
                context.insert(assistant)

                var calls: [Int: ToolCall] = [:]
                for try await event in client.streamChat(messages: transcript, tools: ToolRegistry.specs) {
                    switch event {
                    case .textDelta(let delta):
                        assistant.content += delta
                    case .toolCallStarted(let index, let id, let name):
                        if var existing = calls[index] {
                            if existing.name.isEmpty { existing.name = name }
                            calls[index] = existing
                        } else {
                            calls[index] = ToolCall(id: id, name: name, arguments: "")
                        }
                    case .toolCallArgumentsDelta(let index, let delta):
                        if calls[index] == nil { calls[index] = ToolCall(id: "call_\(index)", name: "", arguments: "") }
                        calls[index]?.arguments += delta
                    case .finished:
                        break
                    }
                }

                let toolCalls = calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.name.isEmpty }
                if toolCalls.isEmpty {
                    if assistant.content.isEmpty { assistant.content = "Done." }
                    task.status = .done
                    task.updatedAt = .now
                    try? context.save()
                    return
                }

                for (i, call) in toolCalls.enumerated() {
                    try Task.checkCancellation()
                    let step = ToolStep(toolCallId: call.id, toolName: call.name, argumentsJSON: call.arguments, order: i)
                    step.message = assistant
                    context.insert(step)
                    let args = JSONValue.parse(call.arguments)

                    guard let tool = ToolRegistry.tool(named: call.name) else {
                        step.status = .failed
                        step.result = "Unknown tool \(call.name)"
                        continue
                    }

                    if tool.requiresApproval && settings.askBeforeActing {
                        let approval = PendingApproval(taskId: task.id, step: step, summary: tool.summary(for: args))
                        approvals[task.id] = approval
                        task.status = .waitingApproval
                        let approved = await approval.wait()
                        approvals[task.id] = nil
                        task.status = .running
                        if !approved {
                            step.status = .denied
                            step.result = "The user declined this action. Do not retry it; ask how they would like to proceed instead."
                            continue
                        }
                    }

                    do {
                        step.result = try await tool.run(args: args, context: toolContext)
                        step.status = .done
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        step.status = .failed
                        step.result = "Error: \(error.localizedDescription)"
                    }
                    try? context.save()
                }
                task.updatedAt = .now
            }
            task.status = .done
            task.lastError = "Stopped after \(maxRounds) steps. Send a follow-up to continue."
        } catch is CancellationError {
            task.status = .idle
            task.lastError = nil
            if let last = task.sortedMessages.last, last.role == .assistant, last.content.isEmpty, last.steps.isEmpty {
                context.delete(last)
            }
        } catch {
            task.status = .failed
            task.lastError = error.localizedDescription
            if let last = task.sortedMessages.last, last.role == .assistant, last.content.isEmpty, last.steps.isEmpty {
                context.delete(last)
            }
        }
        task.updatedAt = .now
        try? context.save()
    }

    // MARK: - Transcript

    private func buildTranscript(task: WorkTask, context: ModelContext, settings: AppSettings) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(systemPrompt(settings: settings, context: context))]
        for message in task.sortedMessages {
            switch message.role {
            case .user:
                var parts: [ContentPart] = []
                var text = message.content
                for att in message.attachments where !att.isImage {
                    if let extracted = att.extractedText {
                        text += "\n\n--- Attached file: \(att.filename) ---\n\(extracted)\n--- end of \(att.filename) ---"
                    } else {
                        text += "\n\n(Attached file \(att.filename) of type \(att.mimeType); contents could not be read as text.)"
                    }
                }
                parts.append(.text(text.isEmpty ? "(see attachments)" : text))
                for att in message.attachments where att.isImage {
                    if let url = AttachmentImporter.dataURL(for: att) { parts.append(.imageURL(url)) }
                }
                messages.append(.user(parts))
            case .assistant:
                let steps = message.sortedSteps
                let calls = steps.map { ToolCall(id: $0.toolCallId, name: $0.toolName, arguments: $0.argumentsJSON.isEmpty ? "{}" : $0.argumentsJSON) }
                if message.content.isEmpty && calls.isEmpty { continue }
                messages.append(.assistant(message.content, toolCalls: calls))
                for step in steps {
                    messages.append(.tool(id: step.toolCallId, result: step.result.isEmpty ? "(no result)" : step.result))
                }
            }
        }
        return messages
    }

    private func systemPrompt(settings: AppSettings, context: ModelContext) -> String {
        let memories = (try? context.fetch(FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        var prompt = """
        You are Sidekick, a personal AI assistant that gets work done on the user's iPhone. You are not just a chatbot: you plan, use tools, and deliver finished results (files, images, calendar changes, research summaries, email drafts).

        Current date/time: \(f.string(from: .now)) (\(TimeZone.current.identifier)).

        How to work:
        - Understand the goal, then act. Use tools proactively instead of asking for things you can look up yourself (calendar, health data, the web, the current time).
        - For research, search first, then read the most relevant pages with fetch_url, and cite sources with their URLs.
        - When the user asks for a document, plan, report, list or copy, create it with create_document (prefer pdf for polished deliverables, markdown for notes, csv for tabular data) and give a short summary in chat.
        - When asked for visuals use generate_image; for clips use generate_video.
        - For scheduling, check list_calendar_events before proposing or creating events; respect the user's existing commitments and timezone. Use ISO 8601 with timezone offsets.
        - For emails, use draft_email so the user can open it in Mail. Match the tone the user asked for.
        - For health questions, read get_health_summary and give practical, non-alarmist guidance. Recommend a professional for anything medical.
        - Save durable personal facts with remember when the user shares them.
        - If a tool fails or the user declines an action, explain briefly and offer an alternative.
        - Be concise and friendly. Use short markdown: headings, bullets, bold. No filler.
        """
        if !settings.userName.isEmpty || !settings.userAbout.isEmpty {
            prompt += "\n\nAbout the user:"
            if !settings.userName.isEmpty { prompt += "\n- Name: \(settings.userName)" }
            if !settings.userAbout.isEmpty { prompt += "\n- \(settings.userAbout)" }
        }
        if !memories.isEmpty {
            prompt += "\n\nThings you remember about the user:\n" + memories.map { "- \($0.text)" }.joined(separator: "\n")
        }
        return prompt
    }

    private static func deriveTitle(from text: String, attachments: [PendingAttachment]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let first = attachments.first { return "About \(first.filename)" }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.count <= 48 { return firstLine }
        return String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
