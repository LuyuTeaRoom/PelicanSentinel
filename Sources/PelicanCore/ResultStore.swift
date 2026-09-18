import Foundation

public final class ResultStore {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default
    public init(root: URL) throws {
        self.root = root
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for directory in [root, root.appendingPathComponent("results"), root.appendingPathComponent("thumbnails")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    public func url(for relativePath: String) -> URL? {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        return candidate.path.hasPrefix(root.standardizedFileURL.path + "/") ? candidate : nil
    }
    public func saveText(_ text: String, id: UUID, suffix: String) throws -> String {
        let relative = "results/\(id.uuidString).\(suffix)"
        try write(Data(text.utf8), to: root.appendingPathComponent(relative))
        return relative
    }
    public func saveThumbnail(_ data: Data, id: UUID) throws -> String {
        let relative = "thumbnails/\(id.uuidString).png"
        try write(data, to: root.appendingPathComponent(relative)); return relative
    }
    public func save(_ record: ResultRecord) throws {
        try write(encoder.encode(record), to: root.appendingPathComponent("results/\(record.id.uuidString).json"))
    }
    public func history() throws -> (records: [ResultRecord], unreadableFiles: [String]) {
        let files = try fm.contentsOfDirectory(at: root.appendingPathComponent("results"), includingPropertiesForKeys: nil)
        var records: [ResultRecord] = [], unreadable: [String] = []
        for file in files where file.pathExtension == "json" {
            do { records.append(try decoder.decode(ResultRecord.self, from: Data(contentsOf: file))) }
            catch { unreadable.append(file.lastPathComponent) }
        }
        return (records.sorted { $0.startedAt > $1.startedAt }, unreadable.sorted())
    }
    public func records() throws -> [ResultRecord] { try history().records }
    public func recoverInterrupted(now: Date = Date()) throws {
        for var record in try records() where record.status == .generating {
            record.status = .interrupted
            record.completedAt = now
            record.errorType = "interrupted"
            record.errorMessage = "The previous run was interrupted. The remote result is uncertain; this attempt will not be resent automatically."
            try save(record)
        }
    }
    public func reconciledSettings(_ settings: AppSettings, now: Date = Date()) throws -> AppSettings {
        var result = settings
        let history = try records()
        if let pending = result.pendingScheduledAt,
           history.contains(where: { $0.matchesSchedule(provider: result.provider, at: pending) }) {
            result.pendingScheduledAt = nil
        }
        if history.contains(where: { $0.matchesSchedule(provider: result.provider, at: result.nextScheduledAt) }),
           let due = SchedulePolicy.consumeDue(next: result.nextScheduledAt, now: now, intervalHours: result.intervalHours) {
            result.nextScheduledAt = due.next
        }
        return result
    }
    public func settings() throws -> AppSettings {
        let url = root.appendingPathComponent("settings.json")
        guard fm.fileExists(atPath: url.path) else { return AppSettings() }
        var settings = try decoder.decode(AppSettings.self, from: Data(contentsOf: url))
        if ![1, 2, 4].contains(settings.intervalHours) { settings.intervalHours = 4 }
        settings.retentionDays = 30
        return settings
    }
    public func saveSettings(_ settings: AppSettings) throws { try write(encoder.encode(settings), to: root.appendingPathComponent("settings.json")) }
    public func needsExportRecovery(_ record: ResultRecord) -> Bool {
        guard record.status == .success, record.imageExportError != nil else { return false }
        guard let path = record.savedSVGPath else { return true }
        return !fm.fileExists(atPath: path)
    }
    public func prune(now: Date = Date(), retentionDays: Int = 30) throws {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for record in try records() where record.completedAt.map({ $0 < cutoff }) == true && record.status != .generating {
            if needsExportRecovery(record) { continue }
            for relative in [record.rawResponsePath, record.svgPath, record.annotatedSVGPath, record.thumbnailPath].compactMap({ $0 }) {
                if let file = url(for: relative), fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
            try fm.removeItem(at: root.appendingPathComponent("results/\(record.id.uuidString).json"))
        }
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct LocalStorageFailure: Error {}

@MainActor
public final class GenerationService {
    private let store: ResultStore
    public private(set) var isGenerating = false
    public private(set) var activeRecordID: UUID?
    public init(store: ResultStore) { self.store = store }

    public func generate(provider: any ModelProvider, settings: AppSettings, scheduledAt: Date? = nil,
                         beforeRequest: (() throws -> Void)? = nil,
                         thumbnail: ((String) async throws -> Data)? = nil) async throws -> ResultRecord {
        guard !isGenerating else { throw ProviderFailure(type: "busy", message: "A generation is already in progress.") }
        isGenerating = true
        defer { isGenerating = false; activeRecordID = nil }
        // A persisted attempt consumes its scheduled slot, even if delivery was uncertain.
        if let scheduledAt, let existing = try store.records().first(where: { $0.matchesSchedule(provider: settings.provider, at: scheduledAt) }) {
            try beforeRequest?()
            return existing
        }
        let configuration = try settings.selectedConfiguration.validated(for: settings.provider)
        let request = try configuration.request(for: settings.provider)
        var record = ResultRecord(providerId: settings.provider, scheduledAt: scheduledAt, completedAt: nil, generationMode: settings.mode, scheduleInterval: settings.intervalHours, status: .generating)
        applyConfiguration(configuration, provider: settings.provider, to: &record)
        try store.save(record) // Never send a request when its initial record cannot be saved.
        activeRecordID = record.id
        do {
            try Task.checkCancellation()
            record.executionProfile = await provider.executionProfile(for: request)
            try Task.checkCancellation()
            try local { try store.save(record); try beforeRequest?() }
            try Task.checkCancellation()
            let response = try await provider.generate(request)
            record.returnedModel = response.returnedModel
            record.usage = response.usage
            record.executionProfile = response.executionProfile
            record.rawResponsePath = try local { try store.saveText(response.rawResponse, id: record.id, suffix: "response.txt") }
            try local { try store.save(record) }
            try Task.checkCancellation()
            if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.status = .emptyResponse; record.errorType = "empty_response"; record.errorMessage = "The model returned no text."
            } else {
                let svg = try SVGExtractor.extract(from: response.content)
                record.svgPath = try local { try store.saveText(svg, id: record.id, suffix: "svg") }
                try local { try store.save(record) }
                try SVGValidator.validate(svg)
                record.status = .success
                if let thumbnail {
                    do {
                        let png = try await thumbnail(svg)
                        try Task.checkCancellation()
                        record.thumbnailPath = try local { try store.saveThumbnail(png, id: record.id) }
                        record.presentationVersion = 2
                    } catch is CancellationError { throw CancellationError() }
                    catch is LocalStorageFailure { throw LocalStorageFailure() }
                    catch { record.errorType = "thumbnail_error"; record.errorMessage = "The SVG was saved, but its thumbnail could not be generated." }
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            record.status = .cancelled; record.errorType = "cancelled"; record.errorMessage = "Local waiting was cancelled. The remote result is uncertain."
        } catch let error as SVGError {
            switch error {
            case .unsafeContent: record.status = .blockedSVG; record.errorType = "unsafe_svg"
            case .tooLarge: record.status = .blockedSVG; record.errorType = "svg_too_large"
            case .tooComplex: record.status = .blockedSVG; record.errorType = "svg_too_complex"
            default: record.status = .invalidSVG; record.errorType = "invalid_svg"
            }
            record.errorMessage = error.localizedDescription
        } catch is LocalStorageFailure {
            record.status = .storageError; record.errorType = "storage_error"; record.errorMessage = "Could not save locally. Check storage permissions and available space."
        } catch let error as ProviderFailure {
            record.status = error.status; record.errorType = error.type; record.errorMessage = error.message
            record.returnedModel = error.returnedModel; record.usage = error.usage
            if let profile = error.executionProfile { record.executionProfile = profile }
            if let raw = error.rawResponse {
                do { record.rawResponsePath = try store.saveText(raw, id: record.id, suffix: "response.txt") }
                catch { record.status = .storageError; record.errorType = "storage_error"; record.errorMessage = "Could not save the failed response. Check storage permissions and available space." }
            }
        } catch {
            record.status = .apiError; record.errorType = "request_failed"; record.errorMessage = "The request did not complete."
        }
        // A bounded shutdown may already have marked this attempt as uncertain.
        if let saved = try store.records().first(where: { $0.id == record.id }), saved.status == .interrupted { return saved }
        let completed = Date()
        record.completedAt = completed
        record.latencyMs = Int(completed.timeIntervalSince(record.startedAt) * 1000)
        try store.save(record)
        return record
    }
    public func interruptActive() throws {
        guard let id = activeRecordID,
              var record = try store.records().first(where: { $0.id == id }), record.status == .generating else { return }
        record.status = .interrupted; record.completedAt = Date()
        record.errorType = "interrupted"; record.errorMessage = "The request was still pending at shutdown; it will not be resent automatically."
        try store.save(record)
    }
    private func applyConfiguration(_ configuration: ProviderConfiguration, provider: ProviderID, to record: inout ResultRecord) {
        record.modelId = configuration.model; record.modelDisplayName = configuration.model; record.requestedModel = configuration.model
        record.reasoningConfig = configuration.reasoning; record.outputLimit = provider == .codex ? 0 : configuration.outputLimit
        record.requestConfiguration = configuration
    }
    private func local<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() } catch { throw LocalStorageFailure() }
    }
    @discardableResult public func skip(settings: AppSettings, scheduledAt: Date) throws -> ResultRecord {
        if let existing = try store.records().first(where: { $0.matchesSchedule(provider: settings.provider, at: scheduledAt) }) { return existing }
        var record = ResultRecord(providerId: settings.provider, scheduledAt: scheduledAt, generationMode: settings.mode, scheduleInterval: settings.intervalHours, status: .skippedByUser)
        applyConfiguration(settings.selectedConfiguration, provider: settings.provider, to: &record)
        try store.save(record); return record
    }
}
