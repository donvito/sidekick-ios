import Foundation
import Observation

/// A downloadable on-device model in LiteRT-LM's `.litertlm` format.
struct LocalModelCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let sizeBytes: Int64
    let downloadURL: URL
    let filename: String
    let supportsVision: Bool

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    /// Public (non-gated) Gemma builds published by Google's LiteRT community org on Hugging Face.
    static let all: [LocalModelCatalogEntry] = [
        LocalModelCatalogEntry(
            id: "gemma-4-E2B-it",
            name: "Gemma 4 E2B",
            detail: "Fastest. Good for everyday chat and quick answers on any recent iPhone.",
            sizeBytes: 2_588_147_712,
            downloadURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
            filename: "gemma-4-E2B-it.litertlm",
            supportsVision: true
        ),
        LocalModelCatalogEntry(
            id: "gemma-4-E4B-it",
            name: "Gemma 4 E4B",
            detail: "Smarter answers and better writing. Needs a recent iPhone with 8 GB RAM.",
            sizeBytes: 3_659_530_240,
            downloadURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
            filename: "gemma-4-E4B-it.litertlm",
            supportsVision: true
        ),
    ]
}

/// A `.litertlm` file that is present on disk, either downloaded from the catalog or imported by the user.
struct InstalledLocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let sizeBytes: Int64
    let catalogEntry: LocalModelCatalogEntry?

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

enum LocalModelError: LocalizedError {
    case notLitertlm
    case download(String)
    case insufficientStorage(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notLitertlm: "Only .litertlm model files are supported."
        case .download(let s): "Download failed: \(s)"
        case .insufficientStorage(let needed, let available):
            "Not enough free space. Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
        }
    }
}

/// Owns the on-disk library of local models and the downloads that populate it.
/// Files live in Application Support (not backed up, not shown in Files) so multi‑GB weights don't bloat iCloud backups.
@MainActor
@Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    struct Download: Identifiable {
        let id: String
        var progress: Double
        var receivedBytes: Int64
        var totalBytes: Int64
    }

    private(set) var installed: [InstalledLocalModel] = []
    private(set) var downloads: [String: Download] = [:]
    private(set) var errors: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    /// Scratch space LiteRT-LM uses for compiled kernels and tokenizer caches.
    nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiteRTLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        installed = urls
            .filter { $0.pathExtension.lowercased() == "litertlm" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let entry = LocalModelCatalogEntry.all.first { $0.filename == url.lastPathComponent }
                return InstalledLocalModel(
                    id: url.lastPathComponent,
                    name: entry?.name ?? url.deletingPathExtension().lastPathComponent,
                    url: url,
                    sizeBytes: size,
                    catalogEntry: entry
                )
            }
            .sorted { $0.name < $1.name }
    }

    func isInstalled(_ entry: LocalModelCatalogEntry) -> Bool {
        installed.contains { $0.id == entry.filename }
    }

    func model(withId id: String) -> InstalledLocalModel? {
        installed.first { $0.id == id }
    }

    // MARK: - Downloads

    func download(_ entry: LocalModelCatalogEntry) {
        guard tasks[entry.id] == nil, !isInstalled(entry) else { return }
        errors[entry.id] = nil
        if let available = Self.availableCapacity(), available < entry.sizeBytes + 500_000_000 {
            errors[entry.id] = LocalModelError.insufficientStorage(needed: entry.sizeBytes, available: available).localizedDescription
            return
        }
        downloads[entry.id] = Download(id: entry.id, progress: 0, receivedBytes: 0, totalBytes: entry.sizeBytes)
        let resume = resumeData.removeValue(forKey: entry.id)
        tasks[entry.id] = Task { [weak self] in
            guard let self else { return }
            let downloader = ModelDownloader()
            self.downloaders[entry.id] = downloader
            do {
                let destination = Self.directory.appendingPathComponent(entry.filename)
                try await downloader.download(entry.downloadURL, resumeData: resume, to: destination) { received, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[entry.id] != nil else { return }
                        let expected = total > 0 ? total : entry.sizeBytes
                        self.downloads[entry.id] = Download(id: entry.id, progress: Double(received) / Double(expected), receivedBytes: received, totalBytes: expected)
                    }
                }
                self.refresh()
                if AppSettings.shared.localModelId.isEmpty { AppSettings.shared.localModelId = entry.filename }
            } catch let error as ModelDownloader.Paused {
                self.resumeData[entry.id] = error.resumeData
                self.errors[entry.id] = error.message
            } catch is CancellationError {
            } catch {
                self.errors[entry.id] = error.localizedDescription
            }
            self.downloads[entry.id] = nil
            self.downloaders[entry.id] = nil
            self.tasks[entry.id] = nil
        }
    }

    /// Stops the transfer but keeps resume data so the next `download` picks up where it left off.
    func cancelDownload(_ entry: LocalModelCatalogEntry) {
        downloaders[entry.id]?.pause()
        downloads[entry.id] = nil
    }

    private var downloaders: [String: ModelDownloader] = [:]
    private var resumeData: [String: Data] = [:]

    // MARK: - Import / delete

    /// Copies a user-picked `.litertlm` file (e.g. a gated Gemma 3n build downloaded from Hugging Face) into the library.
    func importModel(from url: URL) throws {
        guard url.pathExtension.lowercased() == "litertlm" else { throw LocalModelError.notLitertlm }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destination = Self.directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        refresh()
        if AppSettings.shared.localModelId.isEmpty { AppSettings.shared.localModelId = destination.lastPathComponent }
    }

    func delete(_ model: InstalledLocalModel) {
        try? FileManager.default.removeItem(at: model.url)
        refresh()
        if AppSettings.shared.localModelId == model.id {
            AppSettings.shared.localModelId = installed.first?.id ?? ""
            LocalLLMEngine.shared.unload()
        }
    }

    nonisolated static func availableCapacity() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Wraps a `URLSessionDownloadTask` (which streams straight to disk on a background queue) in async/await.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Paused: Error {
        let resumeData: Data?
        var message: String? = nil
    }

    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: ((Int64, Int64) -> Void)?
    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var pausing = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func download(_ url: URL, resumeData: Data?, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        self.destination = destination
        self.progress = progress
        defer { session.finishTasksAndInvalidate() }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                continuation = c
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            task?.cancel()
        }
    }

    func pause() {
        pausing = true
        task?.cancel { [weak self] data in
            self?.finish(.failure(Paused(resumeData: data)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw LocalModelError.download("HTTP \(http.statusCode)")
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if pausing { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else if let resume {
            finish(.failure(Paused(resumeData: resume, message: "Download interrupted: \(error.localizedDescription) Tap Download to resume.")))
        } else {
            finish(.failure(LocalModelError.download(error.localizedDescription)))
        }
    }
}
