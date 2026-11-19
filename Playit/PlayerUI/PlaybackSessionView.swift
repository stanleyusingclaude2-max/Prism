import SwiftUI
import PlayitCore

@MainActor
struct PlaybackSessionView: View {
    let session: PlaybackSession
    let library: LibraryStore
    let onAutoLockChange: (Bool) -> Void
    @State private var index: Int
    @State private var fullscreen = false
    /// Shared by consecutive videos so landscape mode does not rotate back and forth.
    @State private var orientationSession: UUID?

    init(session: PlaybackSession, library: LibraryStore, onAutoLockChange: @escaping (Bool) -> Void) {
        self.session = session
        self.library = library
        self.onAutoLockChange = onAutoLockChange
        _index = State(initialValue: session.initialIndex)
    }

    var body: some View {
        let position = index
        let entry = session.entries[position]
        VideoPlayerScreen(
            entry: entry, entries: session.entries, index: position,
            startsFullscreen: fullscreen,
            resumePosition: entry.isExternal ? nil : library.resumePosition(for: entry.item),
            orientationSession: $orientationSession,
            onFullscreenChange: { fullscreen = $0 },
            onAutoLockChange: { if index == position { onAutoLockChange($0) } },
            onSelect: { index = $0 },
            onSaveExternal: { try await library.saveOpenedVideo(entry.url) },
            onMetadata: { duration, width, height in
                guard !entry.isExternal else { return }
                Task { await library.recordMetadata(for: entry.item, duration: duration, width: width, height: height) }
            },
            onPlaybackPosition: { seconds, duration in
                guard !entry.isExternal else { return }
                Task { await library.recordPlaybackPosition(for: entry.item, position: seconds, duration: duration) }
            }
        )
        .id(entry.id)
    }
}
