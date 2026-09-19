import Foundation
import SwiftData

enum TaskStatus: String, Codable {
    case idle, running, waitingApproval, done, failed
}

enum MessageRole: String, Codable {
    case user, assistant
}

enum StepStatus: String, Codable {
    case running, done, failed, denied
}

enum ArtifactKind: String, Codable, CaseIterable {
    case document, image, video, email

    var label: String {
        switch self {
        case .document: "Documents"
        case .image: "Images"
        case .video: "Videos"
        case .email: "Emails"
        }
    }

    var systemImage: String {
        switch self {
        case .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .email: "envelope"
        }
    }
}

@Model
final class WorkTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var category: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var lastError: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.task)
    var messages: [ChatMessage] = []

    @Relationship(deleteRule: .cascade, inverse: \Artifact.task)
    var artifacts: [Artifact] = []

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .idle }
        set { statusRaw = newValue.rawValue }
    }

    var sortedMessages: [ChatMessage] { messages.sorted { $0.order < $1.order } }

    init(title: String, category: String = "General") {
        self.id = UUID()
        self.title = title
        self.category = category
        self.statusRaw = TaskStatus.idle.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var order: Int
    var createdAt: Date
    var task: WorkTask?

    @Relationship(deleteRule: .cascade, inverse: \ToolStep.message)
    var steps: [ToolStep] = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment] = []

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var sortedSteps: [ToolStep] { steps.sorted { $0.order < $1.order } }

    init(role: MessageRole, content: String, order: Int) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.order = order
        self.createdAt = .now
    }
}

@Model
final class ToolStep {
    @Attribute(.unique) var id: UUID
    var toolCallId: String
    var toolName: String
    var argumentsJSON: String
    var result: String
    var statusRaw: String
    var order: Int
    var message: ChatMessage?

    var status: StepStatus {
        get { StepStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }

    init(toolCallId: String, toolName: String, argumentsJSON: String, order: Int) {
        self.id = UUID()
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.result = ""
        self.statusRaw = StepStatus.running.rawValue
        self.order = order
    }
}

@Model
final class Attachment {
    @Attribute(.unique) var id: UUID
    var filename: String
    var mimeType: String
    var relativePath: String
    var extractedText: String?
    var message: ChatMessage?

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var url: URL { FileStore.url(for: relativePath) }

    init(filename: String, mimeType: String, relativePath: String, extractedText: String? = nil) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.relativePath = relativePath
        self.extractedText = extractedText
    }
}

@Model
final class Artifact {
    @Attribute(.unique) var id: UUID
    var title: String
    var kindRaw: String
    var filename: String
    var mimeType: String
    var relativePath: String
    var createdAt: Date
    var task: WorkTask?

    var kind: ArtifactKind {
        get { ArtifactKind(rawValue: kindRaw) ?? .document }
        set { kindRaw = newValue.rawValue }
    }

    var url: URL { FileStore.url(for: relativePath) }

    init(title: String, kind: ArtifactKind, filename: String, mimeType: String, relativePath: String) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.filename = filename
        self.mimeType = mimeType
        self.relativePath = relativePath
        self.createdAt = .now
    }
}

@Model
final class MemoryItem {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.createdAt = .now
    }
}

enum FileStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sidekick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func write(_ data: Data, folder: String, filename: String) throws -> String {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let unique = "\(Int(Date().timeIntervalSince1970))-\(safe)"
        try data.write(to: dir.appendingPathComponent(unique))
        return "\(folder)/\(unique)"
    }
}
