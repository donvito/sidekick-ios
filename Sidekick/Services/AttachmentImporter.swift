import Foundation
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// A file or image the user picked, before it is persisted to a message.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var extractedText: String?

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var thumbnail: UIImage? { isImage ? UIImage(data: data) : nil }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool { lhs.id == rhs.id }
}

enum AttachmentImporter {
    static let maxImageDimension: CGFloat = 1536

    static func fromImage(_ image: UIImage, filename: String = "photo.jpg") -> PendingAttachment? {
        let scaled = downscale(image)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return PendingAttachment(filename: filename, mimeType: "image/jpeg", data: data)
    }

    static func fromFile(url: URL) throws -> PendingAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        if type.conforms(to: .image), let img = UIImage(data: data) {
            return fromImage(img, filename: url.lastPathComponent) ?? PendingAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
        }
        var text: String?
        if type.conforms(to: .pdf) {
            text = extractPDFText(data: data)
        } else if type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) || type.conforms(to: .sourceCode) {
            text = String(data: data, encoding: .utf8)
        }
        return PendingAttachment(filename: url.lastPathComponent, mimeType: mime, data: data, extractedText: text.map { String($0.prefix(60_000)) })
    }

    static func extractPDFText(data: Data) -> String? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var text = ""
        for i in 0..<min(doc.pageCount, 60) {
            if let page = doc.page(at: i), let s = page.string { text += s + "\n\n" }
        }
        return text.isEmpty ? nil : text
    }

    static func downscale(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxImageDimension else { return image }
        let scale = maxImageDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func dataURL(for attachment: Attachment) -> String? {
        guard attachment.isImage, let data = try? Data(contentsOf: attachment.url) else { return nil }
        return "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
    }
}
