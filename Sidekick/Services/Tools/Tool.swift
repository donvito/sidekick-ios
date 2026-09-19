import Foundation
import SwiftData

/// Everything a tool may need while running: the current task (to attach artifacts) and settings.
@MainActor
struct ToolContext {
    let task: WorkTask
    let modelContext: ModelContext
    let settings: AppSettings

    func addArtifact(title: String, kind: ArtifactKind, filename: String, mimeType: String, data: Data) throws -> Artifact {
        let path = try FileStore.write(data, folder: kind.rawValue + "s", filename: filename)
        let artifact = Artifact(title: title, kind: kind, filename: filename, mimeType: mimeType, relativePath: path)
        artifact.task = task
        modelContext.insert(artifact)
        try modelContext.save()
        return artifact
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    /// Side-effecting tools ask the user first when "Ask before acting" is on.
    var requiresApproval: Bool { get }
    /// Human readable summary of what the call will do, shown in the timeline/approval card.
    func summary(for args: JSONValue) -> String
    func run(args: JSONValue, context: ToolContext) async throws -> String
}

extension AgentTool {
    var requiresApproval: Bool { false }
    var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: parameters) }
}

enum ToolRegistry {
    static let all: [AgentTool] = [
        DateTimeTool(),
        WebSearchTool(),
        FetchURLTool(),
        ListCalendarEventsTool(),
        CreateCalendarEventTool(),
        CreateReminderTool(),
        HealthSummaryTool(),
        CreateDocumentTool(),
        GenerateImageTool(),
        GenerateVideoTool(),
        DraftEmailTool(),
        RememberTool(),
    ]

    static func tool(named name: String) -> AgentTool? {
        all.first { $0.name == name }
    }

    static var specs: [ToolSpec] { all.map(\.spec) }
}
