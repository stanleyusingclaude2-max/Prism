import Foundation
import PlayitCore

/// Retained by both the presentation and decoder until the file is closed.
final class PlaybackFileAccess: @unchecked Sendable {
    private let source: URL
    private let openedScope: Bool

    init(source: URL) {
        self.source = source
        openedScope = source.startAccessingSecurityScopedResource()
    }

    deinit {
        if openedScope { source.stopAccessingSecurityScopedResource() }
    }

    func prepare() throws -> PlaybackEntry {
        var coordinationError: NSError?
        var result: Result<PlaybackEntry, Error>?
        // File providers can fetch a placeholder here. Never wait on the UI thread.
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { throw MediaLibraryError.unsupportedFile }
                let reader = try FileHandle(forReadingFrom: url)
                try reader.close()
                let item = MediaItem(relativePath: UUID().uuidString, filename: source.lastPathComponent, kind: .video,
                                     byteCount: Int64(values.fileSize ?? 0),
                                     modifiedAt: values.contentModificationDate ?? Date())
                return PlaybackEntry(item: item, url: url, fileAccess: self)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw MediaLibraryError.fileNotFound }
        return try result.get()
    }
}

struct PlaybackEntry: Identifiable, Sendable {
    let item: MediaItem
    let url: URL
    var fileAccess: PlaybackFileAccess? = nil
    var id: String { item.id }
    var isExternal: Bool { fileAccess != nil }
}

struct PlaybackSession: Identifiable {
    let id = UUID()
    let entries: [PlaybackEntry]
    let initialIndex: Int
}
