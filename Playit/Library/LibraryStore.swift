import Foundation
import Combine
import AVFoundation
import ImageIO
import PlayitCore

private func ancestorFolders(of folders: [String]) -> Set<String> {
    var result = Set<String>()
    for folder in folders {
        var path = folder
        while !path.isEmpty && path != "." {
            result.insert(path)
            path = (path as NSString).deletingLastPathComponent
        }
    }
    return result
}

private func isMissingFileError(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSCocoaErrorDomain &&
        [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(error.code)
}

struct FolderRemoval: Equatable {
    let revision: UInt64
    let paths: Set<String>
}

private actor LibraryWorker {
    let repository: MediaLibraryRepository

    init(rootURL: URL) { repository = MediaLibraryRepository(rootURL: rootURL) }
    func scan() throws -> [MediaItem] { try repository.scan() }
    func importFile(_ url: URL, into folder: String?) throws -> MediaItem {
        try repository.importFile(from: url, into: folder)
    }

    func importOpenedVideo(_ url: URL) throws {
        var coordinationError: NSError?
        var copyResult: Result<MediaItem, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            copyResult = Result { try repository.importFile(from: coordinatedURL, into: nil) }
        }
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw MediaLibraryError.fileNotFound }
        _ = try copyResult.get()
    }
    func createFolder(_ name: String, in folder: String?) throws { _ = try repository.createFolder(named: name, in: folder) }
    func rename(_ item: MediaItem, to name: String) throws { _ = try repository.rename(item: item, to: name) }
    func move(_ items: [MediaItem], to folder: String?) throws -> Set<String> {
        _ = try repository.move(items: items, to: folder)
        return missingFolders(in: ancestorFolders(of: items.map(\.folderPath)))
    }
    func delete(_ items: [MediaItem]) throws -> Set<String> {
        try repository.delete(items: items)
        return missingFolders(in: ancestorFolders(of: items.map(\.folderPath)))
    }
    func deleteFolder(at path: String) throws -> Set<String> {
        try repository.deleteFolder(at: path)
        return missingFolders(in: ancestorFolders(of: [path]))
    }
    func cleanupEmptyFolders() throws -> Set<String> { Set(try repository.cleanupEmptyFolders()) }
    func folders(in folder: String?) throws -> [MediaFolder] { try repository.folders(in: folder) }

    func missingFolders(in candidates: Set<String>) -> Set<String> {
        // These paths come from the repository-validated sources of a committed
        // operation. Check only those ancestors, avoiding repeated library scans.
        Set(candidates.filter { path in
            do {
                let values = try repository.rootURL.appendingPathComponent(path)
                    .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory != true || values.isSymbolicLink == true
            } catch { return isMissingFileError(error) }
        })
    }

    func allFolders() throws -> [MediaFolder] {
        var queue: [String?] = [nil]
        var result: [MediaFolder] = []
        while !queue.isEmpty {
            let children = try repository.folders(in: queue.removeFirst())
            result.append(contentsOf: children)
            queue.append(contentsOf: children.map { Optional($0.path) })
        }
        return result
    }

    func saveMetadata(_ item: MediaItem) throws {
        try repository.setMetadata(for: item, duration: item.duration, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight)
    }

    /// One index write for a whole batch of background metadata reads.
    func saveMetadata(batch items: [MediaItem]) throws {
        try repository.setMetadata(items)
    }

    func savePlaybackPosition(_ item: MediaItem) throws {
        try repository.setPlaybackPosition(for: item, position: item.playbackPosition, playedAt: item.lastPlayedAt ?? Date())
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    let rootURL: URL
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isImporting = false
    @Published private(set) var isLoading = false
    @Published private(set) var revision = 0
    @Published private(set) var queryRevision = 0
    @Published private(set) var folderRemoval = FolderRemoval(revision: 0, paths: [])
    @Published var errorMessage: String?
    @Published private(set) var importProgress = ""

    private let worker: LibraryWorker
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestedAgain = false
    private var metadataTask: Task<Void, Never>?
    private var attemptedMetadata = Set<String>()
    private var deletingFolderPaths = Set<String>()
    private var didCleanEmptyFoldersOnLaunch = false
    private var startupCleanupTask: Task<Set<String>, Error>?

    init(rootURL: URL) {
        self.rootURL = rootURL
        worker = LibraryWorker(rootURL: rootURL)
    }

    func url(for item: MediaItem) -> URL {
        // MediaItem paths originate exclusively from the validated repository.
        rootURL.appendingPathComponent(item.relativePath)
    }

    /// Rescans the library. Calls that arrive while a scan is running share one
    /// follow-up scan: a Wi-Fi transfer of hundreds of files refreshes after every
    /// file, and each scan replaces the whole list the grid is showing.
    func refresh() async {
        if let running = refreshTask {
            refreshRequestedAgain = true
            // The running task scans again before finishing, so this call's
            // changes are included when it completes.
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshRequestedAgain = false
                await scanLibrary()
            } while refreshRequestedAgain
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func scanLibrary() async {
        isLoading = true
        await cleanupEmptyFoldersOnLaunch()
        do {
            let snapshot = try await worker.scan()
            // A request that arrived during the scan may follow a delete or move
            // this scan missed. Its scan replaces this one, so stale rows never return.
            guard !refreshRequestedAgain else { return }
            items = snapshot
            revision += 1
            queryRevision += 1
            isLoading = false
            loadMissingMetadata(in: snapshot)
        } catch {
            guard !refreshRequestedAgain else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func cleanupEmptyFoldersOnLaunch() async {
        guard !didCleanEmptyFoldersOnLaunch else { return }
        let task: Task<Set<String>, Error>
        if let existing = startupCleanupTask { task = existing }
        else {
            task = Task { [worker] in try await worker.cleanupEmptyFolders() }
            startupCleanupTask = task
        }
        do {
            let removed = try await task.value
            guard !didCleanEmptyFoldersOnLaunch else { return }
            didCleanEmptyFoldersOnLaunch = true
            startupCleanupTask = nil
            recordRemovedFolders(removed)
        } catch {
            guard !didCleanEmptyFoldersOnLaunch else { return }
            didCleanEmptyFoldersOnLaunch = true
            startupCleanupTask = nil
            errorMessage = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL]) async { await importFiles(urls, into: nil) }

    func importFiles(_ urls: [URL], into folder: String?) async {
        guard !isImporting else { return }
        isImporting = true
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            importProgress = "正在导入 \(index + 1) / \(urls.count)"
            let scoped = url.startAccessingSecurityScopedResource()
            do { _ = try await worker.importFile(url, into: folder) }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        isImporting = false
        importProgress = ""
        await refresh()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    /// The player already holds the file provider's access scope.
    func saveOpenedVideo(_ url: URL) async throws {
        try await worker.importOpenedVideo(url)
        await refresh()
    }

    func createFolder(named name: String, in folder: String?) async {
        await cleanupEmptyFoldersOnLaunch()
        do { try await worker.createFolder(name, in: folder); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func rename(_ item: MediaItem, to name: String) async {
        do { try await worker.rename(item, to: name); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func move(_ items: [MediaItem], to folder: String?) async {
        do {
            recordRemovedFolders(try await worker.move(items, to: folder))
            await refresh()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func delete(_ items: [MediaItem]) async {
        do {
            recordRemovedFolders(try await worker.delete(items))
            await refresh()
        }
        catch { errorMessage = error.localizedDescription; await refresh() }
    }

    @discardableResult
    func deleteFolder(_ folder: MediaFolder) async -> Bool {
        guard deletingFolderPaths.insert(folder.path).inserted else { return false }
        defer { deletingFolderPaths.remove(folder.path) }
        do {
            let removed = try await worker.deleteFolder(at: folder.path)
            // The filesystem mutation has committed. Invalidate the old rows
            // even if a subsequent scan fails or is superseded by another one.
            items.removeAll { $0.folderPath == folder.path || $0.folderPath.hasPrefix(folder.path + "/") }
            revision += 1
            queryRevision += 1
            recordRemovedFolders(removed)
            await refresh()
            return true
        } catch {
            let message = error.localizedDescription
            await refresh()
            errorMessage = message
            return false
        }
    }

    private func recordRemovedFolders(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        // A revision makes repeated removal of a recreated path a fresh event.
        // This is an event, rather than a permanent tombstone for that name.
        folderRemoval = FolderRemoval(revision: folderRemoval.revision &+ 1, paths: paths)
    }

    func folders(in folder: String?) async -> [MediaFolder] {
        await cleanupEmptyFoldersOnLaunch()
        guard !Task.isCancelled, !isDeletingFolderPath(folder) else { return [] }
        do {
            let snapshot = try await worker.folders(in: folder)
            guard !Task.isCancelled, !isDeletingFolderPath(folder) else { return [] }
            return snapshot
        } catch {
            // A cancelled browser or a directory being removed must not publish
            // an obsolete "not found" error over the successful delete result.
            if !Task.isCancelled, !isDeletingFolderPath(folder) {
                if isMissingFileError(error), let folder {
                    let missing = await worker.missingFolders(in: ancestorFolders(of: [folder]))
                    if !Task.isCancelled { recordRemovedFolders(missing) }
                }
                else { errorMessage = error.localizedDescription }
            }
            return []
        }
    }

    private func isDeletingFolderPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return deletingFolderPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func allFolders() async -> [MediaFolder] {
        await cleanupEmptyFoldersOnLaunch()
        do { return try await worker.allFolders() }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    /// The playback decoder can supply metadata for containers AVFoundation
    /// cannot inspect. This updates future searches/sorts and persists it.
    func recordMetadata(for original: MediaItem, duration: Double?, width: Int? = nil, height: Int? = nil) async {
        guard let index = items.firstIndex(where: { $0.id == original.id && $0.modifiedAt == original.modifiedAt }) else { return }
        var item = items[index]
        if let duration, duration.isFinite, duration > 0 { item.duration = duration }
        if let width, width > 0 { item.pixelWidth = width }
        if let height, height > 0 { item.pixelHeight = height }
        guard item != items[index] else { return }
        items[index] = item
        queryRevision += 1
        try? await worker.saveMetadata(item)
    }

    /// Remembers where a library video stopped, or forgets it when it was watched
    /// to the end. The next playback of the same file starts from that position.
    func recordPlaybackPosition(for original: MediaItem, position: Double, duration: Double) async {
        guard let index = items.firstIndex(where: {
            $0.id == original.id && $0.modifiedAt == original.modifiedAt && $0.byteCount == original.byteCount
        }) else { return }
        var item = items[index]
        item.playbackPosition = PlaybackResumePolicy.storedPosition(position: position, duration: duration)
        item.lastPlayedAt = Date()
        if (item.duration ?? 0) <= 0, duration.isFinite, duration > 0 { item.duration = duration }
        items[index] = item
        // Library rows show the watched share on their thumbnails.
        queryRevision += 1
        try? await worker.savePlaybackPosition(item)
    }

    /// The latest remembered position for a library item, validated for resuming.
    func resumePosition(for original: MediaItem) -> Double? {
        let latest = items.first { $0.id == original.id && $0.modifiedAt == original.modifiedAt } ?? original
        return PlaybackResumePolicy.resumePosition(stored: latest.playbackPosition, duration: latest.duration)
    }

    /// Files read at the same time by the background metadata pass.
    private static let metadataReadWidth = 4
    /// Results are published at most this often, or sooner once this many are ready.
    private static let metadataFlushInterval: Duration = .milliseconds(700)
    private static let metadataBatchSize = 64

    private static func metadataKey(_ item: MediaItem) -> String {
        item.relativePath + ":" + String(item.modifiedAt.timeIntervalSince1970) + ":" + String(item.byteCount)
    }

    private static func needsMetadata(_ item: MediaItem) -> Bool {
        (item.pixelWidth ?? 0) <= 0 || (item.pixelHeight ?? 0) <= 0 ||
            (item.kind == .video && (item.duration ?? 0) <= 0)
    }

    /// Reads missing durations and pixel sizes in the background. Results reach
    /// the library in batches, one list change and one index write per batch.
    /// Publishing every file separately made a large photo import re-render
    /// the whole grid many times a second, which is what made scrolling stall.
    private func loadMissingMetadata(in snapshot: [MediaItem]) {
        let previous = metadataTask
        previous?.cancel()
        metadataTask = Task { [weak self] in
            // A cancelled pass first returns the files it did not finish.
            if let previous { await previous.value }
            guard let self, !Task.isCancelled else { return }
            let pending = snapshot.filter {
                Self.needsMetadata($0) && !attemptedMetadata.contains(Self.metadataKey($0))
            }
            var batch: [MediaItem] = []
            var lastFlush = ContinuousClock.now
            var start = 0
            while start < pending.count, !Task.isCancelled {
                let group = Array(pending[start..<min(start + Self.metadataReadWidth, pending.count)])
                start += group.count
                let keys = group.map { Self.metadataKey($0) }
                attemptedMetadata.formUnion(keys)
                let enriched = await Self.readMetadata(group.map { (item: $0, url: url(for: $0)) })
                if Task.isCancelled {
                    // The pass that replaced this one reads these files again.
                    attemptedMetadata.subtract(keys)
                    break
                }
                batch.append(contentsOf: enriched)
                if batch.count >= Self.metadataBatchSize || lastFlush.duration(to: .now) >= Self.metadataFlushInterval {
                    await applyMetadata(batch)
                    batch.removeAll(keepingCapacity: true)
                    lastFlush = .now
                }
            }
            await applyMetadata(batch)
        }
    }

    /// Runs on the global executor; each file is read in its own child task.
    private nonisolated static func readMetadata(_ files: [(item: MediaItem, url: URL)]) async -> [MediaItem] {
        await withTaskGroup(of: MediaItem.self, returning: [MediaItem].self) { group in
            for file in files {
                let item = file.item
                let url = file.url
                group.addTask(priority: .utility) { await MediaMetadata.read(item, at: url) }
            }
            var results: [MediaItem] = []
            for await item in group { results.append(item) }
            return results
        }
    }

    /// Merges a batch of background reads into the list with a single change.
    private func applyMetadata(_ enriched: [MediaItem]) async {
        guard !enriched.isEmpty else { return }
        var updated = items
        var positions: [String: Int] = [:]
        positions.reserveCapacity(updated.count)
        for (index, item) in updated.enumerated() { positions[item.id] = index }
        var changed: [MediaItem] = []
        for read in enriched {
            // The file may have been replaced or removed while it was being read.
            guard let index = positions[read.id],
                  updated[index].modifiedAt == read.modifiedAt,
                  updated[index].byteCount == read.byteCount else { continue }
            var merged = updated[index]
            if (merged.duration ?? 0) <= 0 { merged.duration = read.duration }
            if (merged.pixelWidth ?? 0) <= 0 { merged.pixelWidth = read.pixelWidth }
            if (merged.pixelHeight ?? 0) <= 0 { merged.pixelHeight = read.pixelHeight }
            guard merged != updated[index] else { continue }
            updated[index] = merged
            changed.append(merged)
        }
        guard !changed.isEmpty else { return }
        items = updated
        queryRevision += 1
        // Unsupported container metadata is optional, never a playback failure.
        try? await worker.saveMetadata(batch: changed)
    }
}

private enum MediaMetadata {
    static func read(_ original: MediaItem, at url: URL) async -> MediaItem {
        var item = original
        if item.kind == .image {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                item.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                item.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            }
        } else {
            if (item.duration ?? 0) <= 0 { item.duration = nil }
            let asset = AVURLAsset(url: url)
            if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 {
                item.duration = time.seconds
            }
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = size.applying(transform)
                if transformed.width.isFinite, transformed.height.isFinite {
                    item.pixelWidth = Int(exactly: abs(transformed.width).rounded())
                    item.pixelHeight = Int(exactly: abs(transformed.height).rounded())
                }
            }
            if item.duration == nil || (item.pixelWidth ?? 0) <= 0 || (item.pixelHeight ?? 0) <= 0,
               let fallback = await MPVMediaProbe.shared.inspect(item, at: url) {
                item.duration = item.duration ?? fallback.duration
                if (item.pixelWidth ?? 0) <= 0 { item.pixelWidth = fallback.width }
                if (item.pixelHeight ?? 0) <= 0 { item.pixelHeight = fallback.height }
            }
        }
        return item
    }
}

extension MediaItem {
    var displaySize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
    var displayDuration: String {
        guard let duration, duration.isFinite,
              let seconds = Int(exactly: max(0, duration).rounded(.down)) else { return "-:--" }
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var displayResolution: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        let short = min(pixelWidth, pixelHeight)
        return short >= 2160 ? "4K" : "\(short)p"
    }
    var displayMetadata: String {
        [fileExtension.uppercased(), displayResolution, displaySize].compactMap { $0 }.joined(separator: " · ")
    }
}
