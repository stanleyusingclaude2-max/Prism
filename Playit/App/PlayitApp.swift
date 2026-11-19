import SwiftUI
import UIKit
import PlayitCore

@main
@MainActor
struct PlayitApp: App {
    @UIApplicationDelegateAdaptor(PlayitOrientationAppDelegate.self) private var orientationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: LibraryStore
    @StateObject private var transfer: TransferStore
    @State private var selectedTab: AppTab = .library
    @State private var activeSession: PlaybackSession?
    @State private var pendingSession: PlaybackSession?
    @State private var playerKeepsScreenOn = false
    @State private var openingFile = false
    @State private var openError: String?
    @State private var openTask: Task<Void, Never>?

    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = LibraryStore(rootURL: root)
        _library = StateObject(wrappedValue: store)
        _transfer = StateObject(wrappedValue: TransferStore(rootURL: root) {
            Task { await store.refresh() }
        })
        AppAppearance.install()
    }

    var body: some Scene {
        WindowGroup {
            presentedTabs
            .task {
                await library.cleanupEmptyFoldersOnLaunch()
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-prism-sample-media") || arguments.contains("-playit-sample-media") {
                    let missing = SampleMedia.urls.filter { !FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent($0.lastPathComponent).path) }
                    if !missing.isEmpty { await library.importFiles(missing) }
                }
                await library.refresh()
            }
            .onOpenURL(perform: openFromFiles)
            .overlay {
                if openingFile {
                    VStack(spacing: 12) {
                        ProgressView("正在打开视频…")
                        Button("取消", action: cancelOpen)
                    }
                    .padding(20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .tint(Theme.accent)
                }
            }
            .alert("无法打开文件", isPresented: Binding(
                get: { openError != nil }, set: { if !$0 { openError = nil } }
            )) {
                Button("知道了", role: .cancel) { openError = nil }
            } message: {
                Text(openError ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { transfer.stop() }
                if phase == .active { Task { await library.refresh() } }
                updateIdleTimer()
            }
            .onChange(of: transfer.isRunning) { _, _ in updateIdleTimer() }
        }
    }

    private var presentedTabs: some View {
        TabView(selection: $selectedTab) {
            LibraryView(store: library, onPlay: playFromLibrary, onTransfer: { selectedTab = .transfer })
                .tabItem { Label { Text("媒体库") } icon: { DesignIcon(name: "IconGrid", size: 23) } }
                .tag(AppTab.library)
            TransferView(store: transfer, library: library)
                .tabItem { Label { Text("传文件") } icon: { DesignIcon(name: "IconTransfer", size: 23) } }
                .tag(AppTab.transfer)
        }
        .tint(Theme.accent)
        .font(AppTypography.body)
        .preferredColorScheme(.dark)
        .background(Theme.bg)
        .background(AppWindowTint().allowsHitTesting(false))
        .fullScreenCover(item: $activeSession, onDismiss: playbackDismissed) { session in
            PlaybackSessionView(session: session, library: library, onAutoLockChange: { keepAwake in
                playerKeepsScreenOn = keepAwake
                updateIdleTimer()
            })
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && (transfer.isRunning || playerKeepsScreenOn)
    }

    private func playFromLibrary(_ selected: MediaItem, _ orderedVideos: [MediaItem]) {
        let entries = orderedVideos.map { PlaybackEntry(item: $0, url: library.url(for: $0)) }
        guard let index = entries.firstIndex(where: { $0.id == selected.id }) else { return }
        cancelOpen()
        present(PlaybackSession(entries: entries, initialIndex: index))
    }

    private func present(_ session: PlaybackSession) {
        if activeSession != nil || pendingSession != nil {
            pendingSession = session
            activeSession = nil
        } else {
            activeSession = session
        }
    }

    private func playbackDismissed() {
        PlaybackOrientationManager.shared.finishPlayerPresentation()
        playerKeepsScreenOn = false
        updateIdleTimer()
        if let pendingSession {
            self.pendingSession = nil
            activeSession = pendingSession
        }
    }

    private func openFromFiles(_ url: URL) {
        cancelOpen()
        openError = nil
        guard url.isFileURL, let kind = MediaKind.classify(fileExtension: url.pathExtension) else {
            openError = MediaLibraryError.unsupportedFile.localizedDescription
            return
        }
        let access = PlaybackFileAccess(source: url)
        selectedTab = .library
        if kind == .image {
            openTask = Task {
                guard !Task.isCancelled else { return }
                await library.importFiles([url])
                withExtendedLifetime(access) {}
            }
            return
        }
        openingFile = true
        openTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try access.prepare() } }.value
            guard !Task.isCancelled else { return }
            openingFile = false
            switch result {
            case .failure(let error):
                openError = error.localizedDescription
            case .success(let external):
                let path = external.url.standardizedFileURL.path
                if path.hasPrefix(library.rootURL.standardizedFileURL.path + "/") {
                    if !library.items.contains(where: { library.url(for: $0).standardizedFileURL.path == path }) {
                        await library.refresh()
                    }
                    guard !Task.isCancelled else { return }
                    let existing = library.items.first(where: { library.url(for: $0).standardizedFileURL.path == path })
                    present(PlaybackSession(entries: [PlaybackEntry(item: existing ?? external.item, url: external.url)], initialIndex: 0))
                    return
                }
                present(PlaybackSession(entries: [external], initialIndex: 0))
            }
        }
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
        openingFile = false
    }

    private enum AppTab: Hashable { case library, transfer }
}

enum SampleMedia {
    static var urls: [URL] {
        [("sample-motion", "mp4"), ("sample-variable", "mkv"), ("sample-legacy", "avi"), ("sample-still", "png"),
         ("sample-portrait", "mov"), ("sample-rotated", "mov")]
            .compactMap { Bundle.main.url(forResource: $0.0, withExtension: $0.1, subdirectory: "Fixtures") }
    }
}
