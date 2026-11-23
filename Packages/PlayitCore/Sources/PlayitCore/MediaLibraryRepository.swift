import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns files below a single app-controlled directory. All filesystem and index
/// operations are serialized; callers should perform potentially large imports
/// and scans away from the main actor.
public final class MediaLibraryRepository: @unchecked Sendable {
    public let rootURL: URL

    private let fileManager = FileManager()
    private let lock = NSRecursiveLock()
    private var catalog: [String: Record]?
    private let indexFilename = ".playit-index.json"

    private struct Record: Codable {
        var importedAt: Date
        var duration: Double?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var byteCount: Int64?
        var modifiedAt: Date?
        // Optional keys added in 0.3.1; older catalogs decode them as nil.
        var playbackPosition: Double?
        var lastPlayedAt: Date?
    }

    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey
    ]

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func scan() throws -> [MediaItem] {
        try serialized {
            try prepare()
            return try scanLocked()
        }
    }

    /// Copies a file into the library. Duplicate names receive a numeric suffix;
    /// the source is never moved or removed.
    @discardableResult
    public func importFile(from sourceURL: URL, into folder: String? = nil) throws -> MediaItem {
        try importFile(from: sourceURL, named: sourceURL.lastPathComponent, into: folder)
    }

    /// File providers may vend a temporary URL with a different name or no extension.
    @discardableResult
    public func importFile(from sourceURL: URL, named filename: String, into folder: String? = nil) throws -> MediaItem {
        try serialized {
            try prepare()
            guard sourceURL.isFileURL,
                  let kind = MediaKind.classify(fileExtension: (filename as NSString).pathExtension)
            else { throw MediaLibraryError.unsupportedFile }
            let sourceValues = try sourceURL.resourceValues(forKeys: resourceKeys)
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true
            else { throw MediaLibraryError.unsupportedFile }

            let destinationFolder = try resolvedPath(folder ?? "", allowRoot: true)
            try requireDirectory(destinationFolder)
            let name = try validatedName(filename)
            let destination = uniqueDestination(name: name, in: destinationFolder)
            try ensureFreeSpace(byteCount: Int64(sourceValues.fileSize ?? 0))
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                    throw MediaLibraryError.insufficientSpace
                }
                throw error
            }
            let relative = try relativePath(of: destination)
            let before = catalog ?? [:]
            catalog?[relative] = Record(importedAt: Date())
            do {
                let item = try item(at: destination, relativePath: relative, kind: kind)
                try saveCatalog()
                return item
            } catch {
                catalog = before
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    @discardableResult
    public func createFolder(named name: String, in folder: String? = nil) throws -> URL {
        try serialized {
            try prepare()
            let parent = try resolvedPath(folder ?? "", allowRoot: true)
            try requireDirectory(parent)
            let destination = parent.appendingPathComponent(try validatedName(name), isDirectory: true)
            guard !entryExists(destination) else {
                throw MediaLibraryError.destinationExists(destination.lastPathComponent)
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return destination
        }
    }

    @discardableResult
    public func rename(item original: MediaItem, to newName: String) throws -> MediaItem {
        try serialized {
            try prepare()
            let source = try existingMediaURL(for: original)
            var filename = try validatedName(newName)
            if (filename as NSString).pathExtension.isEmpty, !source.pathExtension.isEmpty {
                filename += "." + source.pathExtension
            }
            guard MediaKind.classify(fileExtension: (filename as NSString).pathExtension) == original.kind else {
                throw MediaLibraryError.unsupportedFile
            }
            let destination = source.deletingLastPathComponent().appendingPathComponent(filename)
            if source.path == destination.path { return try item(at: source, relativePath: original.relativePath) }
            guard !entryExists(destination) else { throw MediaLibraryError.destinationExists(filename) }
            let oldCatalog = catalog ?? [:]
            let newRelative = try relativePath(of: destination)
            try fileManager.moveItem(at: source, to: destination)
            let movedRecord = catalog?.removeValue(forKey: original.relativePath)
            catalog?[newRelative] = movedRecord
            do {
                let renamed = try item(at: destination, relativePath: newRelative)
                try saveCatalog()
                return renamed
            } catch {
                try? fileManager.moveItem(at: destination, to: source)
                catalog = oldCatalog
                throw error
            }
        }
    }

    /// All destinations are validated before moving anything. A failed move
    /// rolls back completed moves, preventing a partial selection from moving.
    @discardableResult
    public func move(items: [MediaItem], to folder: String?) throws -> [MediaItem] {
        try serialized {
            try prepare()
            let destinationFolder = try resolvedPath(folder ?? "", allowRoot: true)
            try requireDirectory(destinationFolder)
            var seen = Set<String>()
            var planned: [(source: URL, destination: URL, oldPath: String, newPath: String)] = []
            var unchanged: [MediaItem] = []
            for original in items {
                guard seen.insert(original.relativePath).inserted else { continue }
                let source = try existingMediaURL(for: original)
                let destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
                if source.path == destination.path { unchanged.append(original); continue }
                let newPath = try relativePath(of: destination)
                guard !entryExists(destination), !planned.contains(where: { $0.newPath == newPath }) else {
                    throw MediaLibraryError.destinationExists(destination.lastPathComponent)
                }
                planned.append((source, destination, original.relativePath, newPath))
            }

            let oldCatalog = catalog ?? [:]
            var completed: [(source: URL, destination: URL)] = []
            do {
                for move in planned {
                    try fileManager.moveItem(at: move.source, to: move.destination)
                    completed.append((move.source, move.destination))
                    let movedRecord = catalog?.removeValue(forKey: move.oldPath)
                    catalog?[move.newPath] = movedRecord
                }
                let moved = try planned.map { try item(at: $0.destination, relativePath: $0.newPath) }
                try saveCatalog()
                let result = Dictionary(uniqueKeysWithValues: (unchanged + moved).map { ($0.id, $0) })
                let destinations = Dictionary(uniqueKeysWithValues: planned.map { ($0.oldPath, $0.newPath) })
                pruneEmptyAncestors(startingAt: planned.map { $0.source.deletingLastPathComponent() },
                                    protecting: [destinationFolder.path])
                return items.compactMap { original in
                    result[destinations[original.id] ?? original.id]
                }.uniquedByID()
            } catch {
                for move in completed.reversed() { try? fileManager.moveItem(at: move.destination, to: move.source) }
                catalog = oldCatalog
                throw error
            }
        }
    }

    /// Moves the selection into a hidden staging directory before committing
    /// its removal. Files are recoverable if a filesystem move fails mid-batch.
    public func delete(items: [MediaItem]) throws {
        try serialized {
            try prepare()
            var seen = Set<String>()
            let sources = try items.filter { seen.insert($0.relativePath).inserted }.map {
                (item: $0, url: try existingMediaURL(for: $0))
            }
            guard !sources.isEmpty else { return }
            let staging = rootURL.appendingPathComponent(".playit-delete-" + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let oldCatalog = catalog ?? [:]
            var completed: [(source: URL, staged: URL)] = []
            do {
                for (index, source) in sources.enumerated() {
                    let staged = staging.appendingPathComponent(String(index))
                    try fileManager.moveItem(at: source.url, to: staged)
                    completed.append((source.url, staged))
                    catalog?.removeValue(forKey: source.item.relativePath)
                }
                try saveCatalog()
            } catch {
                for move in completed.reversed() { try? fileManager.moveItem(at: move.staged, to: move.source) }
                catalog = oldCatalog
                if (try? fileManager.contentsOfDirectory(atPath: staging.path).isEmpty) == true {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }
            // After commit, cleanup cannot turn a successful deletion into a
            // misleading failure. Mark residual files for retry on next open.
            try? Data().write(to: staging.appendingPathComponent(".committed"), options: .atomic)
            try? fileManager.removeItem(at: staging)
            pruneEmptyAncestors(startingAt: sources.map { $0.url.deletingLastPathComponent() })
        }
    }

    /// Explicitly removes a folder and all its contents, then removes any
    /// ancestors that become truly empty after the deletion has committed.
    /// The directory is staged as a single item, so an index failure can
    /// restore the original tree without partially deleting its contents.
    public func deleteFolder(at path: String) throws {
        try serialized {
            try prepare()
            let source = try resolvedPath(path, allowRoot: false)
            guard entryExists(source) else { throw MediaLibraryError.fileNotFound }
            try requireDirectory(source)
            let staging = rootURL.appendingPathComponent(".playit-delete-" + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let staged = staging.appendingPathComponent("0", isDirectory: true)
            let oldCatalog = catalog ?? [:]
            var moved = false
            do {
                try fileManager.moveItem(at: source, to: staged)
                moved = true
                let prefix = path + "/"
                catalog = catalog?.filter { !$0.key.hasPrefix(prefix) }
                try saveCatalog()
            } catch {
                if moved { try? fileManager.moveItem(at: staged, to: source) }
                catalog = oldCatalog
                if (try? fileManager.contentsOfDirectory(atPath: staging.path).isEmpty) == true {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }
            try? Data().write(to: staging.appendingPathComponent(".committed"), options: .atomic)
            try? fileManager.removeItem(at: staging)
            pruneEmptyAncestors(startingAt: [source.deletingLastPathComponent()])
        }
    }

    /// Removes a mixed selection of folders and files as one operation. The
    /// whole selection is validated first and every entry is staged before the
    /// index is committed, so a failure restores all of it. A folder inside
    /// another selected folder, and a file inside a selected folder, leave with
    /// that folder. Ancestors that become empty are removed afterwards, as with
    /// `delete(items:)` and `deleteFolder(at:)`.
    public func delete(folders folderPaths: [String], items: [MediaItem]) throws {
        try serialized {
            try prepare()
            let selected = Set(folderPaths)
            let outermost = selected.filter { path in
                !selected.contains { other in path.hasPrefix(other + "/") }
            }.sorted()
            func isInsideSelectedFolder(_ relativePath: String) -> Bool {
                outermost.contains { relativePath.hasPrefix($0 + "/") }
            }
            var folders: [URL] = []
            for path in outermost {
                let url = try resolvedPath(path, allowRoot: false)
                guard entryExists(url) else { throw MediaLibraryError.fileNotFound }
                try requireDirectory(url)
                folders.append(url)
            }
            var seen = Set<String>()
            let files = try items
                .filter { seen.insert($0.relativePath).inserted && !isInsideSelectedFolder($0.relativePath) }
                .map { (item: $0, url: try existingMediaURL(for: $0)) }
            guard !folders.isEmpty || !files.isEmpty else { return }

            let staging = rootURL.appendingPathComponent(".playit-delete-" + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let oldCatalog = catalog ?? [:]
            var completed: [(source: URL, staged: URL)] = []
            do {
                for (index, folder) in folders.enumerated() {
                    let staged = staging.appendingPathComponent("folder-\(index)", isDirectory: true)
                    try fileManager.moveItem(at: folder, to: staged)
                    completed.append((folder, staged))
                }
                for (index, file) in files.enumerated() {
                    let staged = staging.appendingPathComponent(String(index))
                    try fileManager.moveItem(at: file.url, to: staged)
                    completed.append((file.url, staged))
                    catalog?.removeValue(forKey: file.item.relativePath)
                }
                catalog = catalog?.filter { !isInsideSelectedFolder($0.key) }
                try saveCatalog()
            } catch {
                for move in completed.reversed() { try? fileManager.moveItem(at: move.staged, to: move.source) }
                catalog = oldCatalog
                if (try? fileManager.contentsOfDirectory(atPath: staging.path).isEmpty) == true {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }
            try? Data().write(to: staging.appendingPathComponent(".committed"), options: .atomic)
            try? fileManager.removeItem(at: staging)
            pruneEmptyAncestors(startingAt: (folders + files.map(\.url)).map { $0.deletingLastPathComponent() })
        }
    }

    /// Removes old empty folder trees, returning only directories actually
    /// removed, with children preceding their parents. Call once on app startup;
    /// scans and folder creation deliberately leave new empty folders usable.
    /// Hidden/internal directories and symbolic links are never traversed.
    /// Unreadable or undeletable subtrees are retained without failing the pass.
    public func cleanupEmptyFolders() throws -> [String] {
        try serialized {
            try prepare()
            let children = try fileManager.contentsOfDirectory(at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
            var stack = children.sorted { $0.path > $1.path }.map { (url: $0, visited: false) }
            var removed: [String] = []
            while let entry = stack.popLast() {
                guard let path = emptyFolderCandidatePath(entry.url) else { continue }
                if entry.visited {
                    if removeEmptyDirectory(at: entry.url) { removed.append(path) }
                    continue
                }
                guard let descendants = try? fileManager.contentsOfDirectory(at: entry.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]) else { continue }
                stack.append((entry.url, true))
                stack.append(contentsOf: descendants.sorted { $0.path > $1.path }.map { ($0, false) })
            }
            return removed
        }
    }

    /// Returns immediate subfolders; counts include all their descendants.
    public func folders(in folder: String? = nil) throws -> [MediaFolder] {
        try serialized {
            try prepare()
            let directory = try resolvedPath(folder ?? "", allowRoot: true)
            try requireDirectory(directory)
            let allMedia = try scanLocked()
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ).compactMap { url -> MediaFolder? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]) else { return nil }
                guard values.isDirectory == true, values.isSymbolicLink != true, values.isHidden != true else { return nil }
                guard let path = try? relativePath(of: url) else { return nil }
                let contained = allMedia.filter { $0.folderPath == path || $0.folderPath.hasPrefix(path + "/") }
                return MediaFolder(
                    path: path,
                    name: url.lastPathComponent,
                    videoCount: contained.filter { $0.kind == .video }.count,
                    imageCount: contained.filter { $0.kind == .image }.count
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Invalid externally-constructed items resolve to a non-existing, hidden
    /// sentinel inside the library, never an arbitrary external filesystem URL.
    public func url(for item: MediaItem) -> URL {
        serialized {
            (try? resolvedPath(item.relativePath, allowRoot: false))
                ?? rootURL.appendingPathComponent(".invalid-media-item")
        }
    }

    /// Caches optional metadata obtained from the platform's actual decoder.
    /// A later size/modification-time change automatically invalidates it.
    public func setMetadata(
        for original: MediaItem,
        duration: Double?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws {
        try serialized {
            try prepare()
            guard try recordMetadataLocked(for: original, duration: duration,
                                           pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { return }
            try saveCatalog()
        }
    }

    /// Caches decoder metadata for many files with a single index write, using
    /// each item's own duration and pixel size. A large import otherwise
    /// rewrites the whole index once per file. Files that were replaced or
    /// removed after they were read are skipped rather than failing the batch.
    public func setMetadata(_ items: [MediaItem]) throws {
        try serialized {
            try prepare()
            var changed = false
            for original in items {
                let recorded = try? recordMetadataLocked(for: original, duration: original.duration,
                                                         pixelWidth: original.pixelWidth,
                                                         pixelHeight: original.pixelHeight)
                if recorded == true { changed = true }
            }
            if changed { try saveCatalog() }
        }
    }

    /// Updates one catalog record without saving. Returns false when the file
    /// no longer matches the version the decoder read.
    private func recordMetadataLocked(
        for original: MediaItem,
        duration: Double?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws -> Bool {
        let source = try existingMediaURL(for: original)
        let current = try item(at: source, relativePath: original.relativePath)
        // The decoder may have been reading while USB replaced the file.
        // Never attach results from an old version to a new fingerprint.
        guard current.byteCount == original.byteCount, current.modifiedAt == original.modifiedAt else { return false }
        var record = catalog?[original.relativePath] ?? Record(importedAt: current.importedAt)
        record.duration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        record.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
        record.pixelHeight = pixelHeight.flatMap { $0 > 0 ? $0 : nil }
        record.byteCount = current.byteCount
        record.modifiedAt = current.modifiedAt
        catalog?[original.relativePath] = record
        return true
    }

    /// Remembers where playback stopped. A nil position forgets it, for example
    /// after the video was watched to the end. Replaced files are never updated.
    public func setPlaybackPosition(for original: MediaItem, position: Double?, playedAt: Date = Date()) throws {
        try serialized {
            try prepare()
            let source = try existingMediaURL(for: original)
            let current = try item(at: source, relativePath: original.relativePath)
            guard current.byteCount == original.byteCount, current.modifiedAt == original.modifiedAt else { return }
            var record = catalog?[original.relativePath] ?? Record(importedAt: current.importedAt)
            record.playbackPosition = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            record.lastPlayedAt = playedAt
            record.byteCount = current.byteCount
            record.modifiedAt = current.modifiedAt
            catalog?[original.relativePath] = record
            try saveCatalog()
        }
    }

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare() throws {
        guard rootURL.isFileURL else { throw MediaLibraryError.invalidPath }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try requireDirectory(rootURL)
        if catalog == nil {
            cleanupCommittedDeletions()
            let index = rootURL.appendingPathComponent(indexFilename)
            guard fileManager.fileExists(atPath: index.path) else { catalog = [:]; return }
            // The catalog is a regenerable cache. A corrupt cache never hides
            // otherwise valid media files from the user.
            catalog = (try? Data(contentsOf: index)).flatMap {
                try? JSONDecoder().decode([String: Record].self, from: $0)
            } ?? [:]
        }
    }

    private func scanLocked() throws -> [MediaItem] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                if url.standardizedFileURL == self.rootURL { enumerationError = error; return false }
                return true
            }
        ) else { throw MediaLibraryError.fileNotFound }

        var results: [MediaItem] = []
        var discovered = Set<String>()
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)
                if values.isSymbolicLink == true || values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true,
                      let kind = MediaKind.classify(fileExtension: url.pathExtension)
                else { continue }
                let relative = try relativePath(of: url)
                results.append(try item(at: url, relativePath: relative, kind: kind))
                discovered.insert(relative)
            } catch {
                // Files can disappear or be replaced during a Finder transfer.
                // One unavailable item must not blank the entire media library.
                continue
            }
        }
        if let enumerationError { throw enumerationError }
        catalog = catalog?.filter { discovered.contains($0.key) }
        // Scanning remains useful when the optional metadata cache is damaged
        // or temporarily unwritable. Mutations still require index commits.
        try? saveCatalog()
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func item(at url: URL, relativePath: String, kind: MediaKind? = nil) throws -> MediaItem {
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let actualKind = kind ?? MediaKind.classify(fileExtension: url.pathExtension)
        else { throw MediaLibraryError.unsupportedFile }
        let modifiedAt = values.contentModificationDate ?? Date.distantPast
        let size = Int64(values.fileSize ?? 0)
        var record = catalog?[relativePath] ?? Record(importedAt: values.creationDate ?? modifiedAt)
        if let previousSize = record.byteCount, let previousModified = record.modifiedAt,
           previousSize != size || previousModified != modifiedAt {
            record.duration = nil
            record.pixelWidth = nil
            record.pixelHeight = nil
            // A replaced file is a different video; its old resume point is meaningless.
            record.playbackPosition = nil
        }
        record.byteCount = size
        record.modifiedAt = modifiedAt
        catalog?[relativePath] = record
        return MediaItem(
            relativePath: relativePath,
            filename: url.lastPathComponent,
            kind: actualKind,
            byteCount: size,
            importedAt: record.importedAt,
            modifiedAt: modifiedAt,
            duration: record.duration,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            playbackPosition: record.playbackPosition,
            lastPlayedAt: record.lastPlayedAt
        )
    }

    private func existingMediaURL(for item: MediaItem) throws -> URL {
        let url = try resolvedPath(item.relativePath, allowRoot: false)
        guard entryExists(url) else { throw MediaLibraryError.fileNotFound }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              MediaKind.classify(fileExtension: url.pathExtension) != nil
        else { throw MediaLibraryError.unsupportedFile }
        return url
    }

    private func saveCatalog() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog ?? [:])
        try data.write(to: rootURL.appendingPathComponent(indexFilename), options: .atomic)
    }

    private func cleanupCommittedDeletions() {
        let prefix = ".playit-delete-"
        let candidates = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for directory in candidates where directory.lastPathComponent.hasPrefix(prefix) {
            guard UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  fileManager.fileExists(atPath: directory.appendingPathComponent(".committed").path)
            else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    /// This is best-effort housekeeping after a committed mutation. Other
    /// files, including hidden and unsupported entries, keep a folder alive.
    @discardableResult
    private func pruneEmptyAncestors(startingAt directories: [URL], protecting protectedPaths: Set<String> = []) -> [String] {
        var removed: [String] = []
        for initial in directories {
            var directory = initial
            while directory.standardizedFileURL.path != rootURL.path {
                guard !protectedPaths.contains(directory.path),
                      let path = emptyFolderCandidatePath(directory),
                      removeEmptyDirectory(at: directory) else { break }
                removed.append(path)
                directory.deleteLastPathComponent()
            }
        }
        return removed
    }

    private func emptyFolderCandidatePath(_ url: URL) -> String? {
        guard let path = try? relativePath(of: url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              values.isHidden != true, !url.lastPathComponent.hasPrefix(".") else { return nil }
        return path
    }

    private func removeEmptyDirectory(at url: URL) -> Bool {
        // Unlike FileManager.removeItem, rmdir cannot recursively delete a file
        // that arrives between checking a directory and removing it. The OS
        // atomically refuses any nonempty directory, including hidden entries.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return rmdir(path) == 0
        }
    }

    private func resolvedPath(_ relativePath: String, allowRoot: Bool) throws -> URL {
        if relativePath.isEmpty {
            guard allowRoot else { throw MediaLibraryError.invalidPath }
            return rootURL
        }
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\") else { throw MediaLibraryError.invalidPath }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw MediaLibraryError.invalidPath }
        for component in components {
            let name = String(component)
            guard !name.isEmpty, !name.hasPrefix("."),
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  name.utf8.count <= 255 else { throw MediaLibraryError.invalidPath }
        }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let canonical = candidate.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(rootURL.path + "/"), canonical.path == candidate.path else {
            throw MediaLibraryError.invalidPath
        }
        // Also reject symlinks that point back inside the library.
        var ancestor = rootURL
        for component in components {
            ancestor.appendPathComponent(String(component))
            if let values = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw MediaLibraryError.invalidPath
            }
        }
        return candidate
    }

    private func relativePath(of url: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let prefix = rootURL.path + "/"
        guard path.hasPrefix(prefix) else { throw MediaLibraryError.invalidPath }
        let relative = String(path.dropFirst(prefix.count))
        _ = try resolvedPath(relative, allowRoot: false)
        return relative
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              trimmed.utf8.count <= 240
        else { throw MediaLibraryError.invalidName }
        return trimmed
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MediaLibraryError.invalidPath }
    }

    private func entryExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func uniqueDestination(name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var suffix = 2
        while entryExists(candidate) {
            let renamed = stem + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
            candidate = directory.appendingPathComponent(renamed)
            suffix += 1
        }
        return candidate
    }

    private func ensureFreeSpace(byteCount: Int64) throws {
        let attributes = try fileManager.attributesOfFileSystem(forPath: rootURL.path)
        if let available = attributes[.systemFreeSize] as? NSNumber, available.int64Value < byteCount {
            throw MediaLibraryError.insufficientSpace
        }
    }
}

private extension Array where Element == MediaItem {
    func uniquedByID() -> [MediaItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
