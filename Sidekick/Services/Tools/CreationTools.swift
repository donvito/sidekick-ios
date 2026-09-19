import Foundation
import UIKit
import SwiftData

struct CreateDocumentTool: AgentTool {
    let name = "create_document"
    let description = "Create a file for the user and save it to their Library. Use for reports, plans, notes, marketing copy, spreadsheets (csv), meeting agendas, etc. Write the full content; markdown is rendered nicely for pdf."
    let parameters = JSONSchema.object([
        "title": JSONSchema.string("Short human title, e.g. 'Q3 Marketing Plan'"),
        "format": JSONSchema.string("File format", enumValues: ["markdown", "pdf", "text", "csv", "html"]),
        "content": JSONSchema.string("Complete file content"),
    ], required: ["title", "format", "content"])

    func summary(for args: JSONValue) -> String { "Creating \(args["format"]?.stringValue ?? "document") “\(args["title"]?.stringValue ?? "")”" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let title = args["title"]?.stringValue, let content = args["content"]?.stringValue else {
            throw ToolError("title and content are required")
        }
        let format = args["format"]?.stringValue ?? "markdown"
        let slug = title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let data: Data
        let ext: String
        let mime: String
        switch format {
        case "pdf":
            data = try await MainActor.run { try PDFRenderer.render(markdown: content, title: title) }
            ext = "pdf"; mime = "application/pdf"
        case "csv":
            data = Data(content.utf8); ext = "csv"; mime = "text/csv"
        case "html":
            data = Data(content.utf8); ext = "html"; mime = "text/html"
        case "text":
            data = Data(content.utf8); ext = "txt"; mime = "text/plain"
        default:
            data = Data(content.utf8); ext = "md"; mime = "text/markdown"
        }
        let artifact = try await context.addArtifact(title: title, kind: .document, filename: "\(slug).\(ext)", mimeType: mime, data: data)
        return "Saved \(format) document “\(title)” to the Library (artifact id \(artifact.id.uuidString)). Tell the user it is available in this task and in the Library tab."
    }
}

struct GenerateImageTool: AgentTool {
    let name = "generate_image"
    let description = "Generate an image from a text prompt (illustrations, social media visuals, logos, concept art). The image is saved to the user's Library."
    let parameters = JSONSchema.object([
        "prompt": JSONSchema.string("Detailed description of the image to generate"),
        "size": JSONSchema.string("Image size", enumValues: ["1024x1024", "1024x1536", "1536x1024"]),
    ], required: ["prompt"])

    func summary(for args: JSONValue) -> String { "Generating an image" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let prompt = args["prompt"]?.stringValue else { throw ToolError("prompt is required") }
        let client = LLMClient()
        let model = await MainActor.run { context.settings.imageModel }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "prompt": .string(prompt),
            "n": .number(1),
            "size": .string(args["size"]?.stringValue ?? "1024x1024"),
        ]
        if !model.hasPrefix("gpt-image") { body["response_format"] = .string("b64_json") }
        let json = try await client.postJSON(path: "/images/generations", body: .object(body))
        guard let first = json["data"]?.arrayValue?.first else {
            throw ToolError("Image provider returned no image. Response: \(json.description.prefix(300))")
        }
        let data: Data
        if let b64 = first["b64_json"]?.stringValue, let d = Data(base64Encoded: b64) {
            data = d
        } else if let urlString = first["url"]?.stringValue, let url = URL(string: urlString) {
            data = try await URLSession.shared.data(from: url).0
        } else {
            throw ToolError("Image provider returned an unsupported payload.")
        }
        let title = String(prompt.prefix(60))
        _ = try await context.addArtifact(title: title, kind: .image, filename: "image.png", mimeType: "image/png", data: data)
        return "Image generated and saved to the Library. Describe it briefly to the user; do not include a URL."
    }
}

struct GenerateVideoTool: AgentTool {
    let name = "generate_video"
    let description = "Generate a short video clip from a text prompt (requires a provider that supports the /videos API, e.g. OpenAI Sora). Takes a minute or more. The video is saved to the Library."
    let parameters = JSONSchema.object([
        "prompt": JSONSchema.string("Description of the video to generate"),
        "seconds": JSONSchema.integer("Duration in seconds (4, 8 or 12). Default 4."),
    ], required: ["prompt"])

    func summary(for args: JSONValue) -> String { "Generating a video (this can take a few minutes)" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let prompt = args["prompt"]?.stringValue else { throw ToolError("prompt is required") }
        let client = LLMClient()
        let model = await MainActor.run { context.settings.videoModel }
        let created = try await client.postJSON(path: "/videos", body: .object([
            "model": .string(model),
            "prompt": .string(prompt),
            "seconds": .string(String(args["seconds"]?.intValue ?? 4)),
        ]))
        guard let id = created["id"]?.stringValue else {
            throw ToolError("Video provider did not return a job id: \(created.description.prefix(300))")
        }
        var status = created["status"]?.stringValue ?? "queued"
        var attempts = 0
        while status != "completed" && attempts < 90 {
            try await Task.sleep(for: .seconds(5))
            try Task.checkCancellation()
            let job = try await client.getJSON(path: "/videos/\(id)")
            status = job["status"]?.stringValue ?? status
            if status == "failed" {
                throw ToolError("Video generation failed: \(job["error"]?["message"]?.stringValue ?? "unknown error")")
            }
            attempts += 1
        }
        guard status == "completed" else { throw ToolError("Video generation timed out. Try again later.") }
        let data = try await client.getData(path: "/videos/\(id)/content")
        _ = try await context.addArtifact(title: String(prompt.prefix(60)), kind: .video, filename: "video.mp4", mimeType: "video/mp4", data: data)
        return "Video generated and saved to the Library."
    }
}

struct EmailDraft: Codable {
    var to: String
    var subject: String
    var body: String
}

struct DraftEmailTool: AgentTool {
    let name = "draft_email"
    let description = "Draft an email for the user. The draft is saved to the Library where the user can review it and open it in their Mail app with one tap. Use for replies, follow-ups, outreach, introductions."
    let parameters = JSONSchema.object([
        "to": JSONSchema.string("Recipient email address(es), comma separated. May be empty if unknown."),
        "subject": JSONSchema.string("Email subject"),
        "body": JSONSchema.string("Full plain-text email body"),
    ], required: ["subject", "body"])

    func summary(for args: JSONValue) -> String { "Drafting email “\(args["subject"]?.stringValue ?? "")”" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue else {
            throw ToolError("subject and body are required")
        }
        let draft = EmailDraft(to: args["to"]?.stringValue ?? "", subject: subject, body: body)
        let data = try JSONEncoder().encode(draft)
        _ = try await context.addArtifact(title: subject, kind: .email, filename: "email.json", mimeType: "application/x-sidekick-email", data: data)
        return "Email draft “\(subject)” saved. The user can open it in Mail from this task. Summarize the draft in one sentence."
    }
}

struct RememberTool: AgentTool {
    let name = "remember"
    let description = "Save a durable fact or preference about the user for future tasks (e.g. 'Works at Acme as head of marketing', 'Prefers morning workouts', 'Partner's name is Ana'). Only store things the user states or clearly implies."
    let parameters = JSONSchema.object([
        "fact": JSONSchema.string("One concise sentence to remember"),
    ], required: ["fact"])

    func summary(for args: JSONValue) -> String { "Remembering: \(args["fact"]?.stringValue ?? "")" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let fact = args["fact"]?.stringValue, !fact.isEmpty else { throw ToolError("fact is required") }
        try await MainActor.run {
            context.modelContext.insert(MemoryItem(text: fact))
            try context.modelContext.save()
        }
        return "Remembered."
    }
}

/// Renders markdown-ish text into a paginated PDF.
@MainActor
enum PDFRenderer {
    static func render(markdown: String, title: String) throws -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let inset: CGFloat = 54
        let textRect = pageRect.insetBy(dx: inset, dy: inset)

        let attributed = NSMutableAttributedString()
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.black]
        var lines = markdown.components(separatedBy: "\n")
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.hasPrefix("# "), first.dropFirst(2).trimmingCharacters(in: .whitespaces) == title {
            lines.removeAll { $0 == first }
        }
        attributed.append(NSAttributedString(string: title + "\n\n", attributes: titleAttrs))

        for rawLine in lines {
            var line = rawLine
            var font = UIFont.systemFont(ofSize: 11.5)
            if line.hasPrefix("### ") { line.removeFirst(4); font = .boldSystemFont(ofSize: 13) }
            else if line.hasPrefix("## ") { line.removeFirst(3); font = .boldSystemFont(ofSize: 15) }
            else if line.hasPrefix("# ") { line.removeFirst(2); font = .boldSystemFont(ofSize: 18) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
            line = line.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`(.+?)`"#, with: "$1", options: .regularExpression)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4
            para.lineSpacing = 2
            attributed.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: para]))
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        var location = 0
        let length = attributed.length
        return renderer.pdfData { ctx in
            while location < length {
                ctx.beginPage()
                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
                let cg = ctx.cgContext
                cg.saveGState()
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: pageRect.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 { break }
                location += visible.length
            }
        }
    }
}
