import AVFoundation
import CryptoKit
import ImageIO
import PlayitCore
import SwiftUI
import UIKit

/// Thread-safe image storage. Library thumbnails stay in memory and in small
/// files under Caches, so a cold launch does not decode every file again.
/// Full-screen photo pages use their own, smaller memory cache: opening a few
/// large pictures must not push the grid's thumbnails out. iOS may purge
/// Caches at any time.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()
    /// Images up to this size are also written to disk; the photo viewer's
    /// 2560 px pages stay in memory only.
    static let diskDimensionLimit = 640

    private let thumbnails = NSCache<NSString, UIImage>()
    private let largeImages = NSCache<NSString, UIImage>()
    private let directory: URL?
    private let lock = NSLock()
    private var unreadable = Set<String>()

    init() {
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        thumbnails.countLimit = 600
        // About six 2560 px photos: swiping back and forth does not decode again.
        largeImages.totalCostLimit = 128 * 1024 * 1024
        largeImages.countLimit = 8
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let folder = caches?.appendingPathComponent("Thumbnails", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        directory = folder
    }

    /// Path, modification time and size identify one version of a file.
    static func key(for item: MediaItem, url: URL, maxDimension: Int) -> String {
        "\(url.path):\(item.modifiedAt.timeIntervalSince1970):\(item.byteCount):\(maxDimension)"
    }

    private func cache(for maxDimension: Int) -> NSCache<NSString, UIImage> {
        maxDimension > Self.diskDimensionLimit ? largeImages : thumbnails
    }

    func memoryImage(forKey key: String, maxDimension: Int) -> UIImage? {
        cache(for: maxDimension).object(forKey: key as NSString)
    }

    func storeInMemory(_ image: UIImage, forKey key: String, maxDimension: Int) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        cache(for: maxDimension).setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Images that could not be decoded are not retried while the app runs.
    func isUnreadable(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unreadable.contains(key)
    }

    func markUnreadable(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if unreadable.count > 1000 { unreadable.removeAll() }
        unreadable.insert(key)
    }

    func diskImage(forKey key: String) -> UIImage? {
        guard let url = fileURL(forKey: key), let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        // Decode now, off the main thread, so the first frame on screen is ready.
        return image.preparingForDisplay() ?? image
    }

    func storeOnDisk(_ image: UIImage, forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        let alpha = image.cgImage?.alphaInfo ?? .premultipliedLast
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        guard let data = opaque ? image.jpegData(compressionQuality: 0.82) : image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(forKey key: String) -> URL? {
        guard let directory else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("thumb")
    }
}

/// Bounds how many image jobs run at once. The newest waiter is served first,
/// so after a fast scroll the cells now on screen fill in before the ones the
/// grid has already passed. A waiter whose task is cancelled leaves the queue
/// without running.
actor ImageWorkLimiter {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let width: Int
    private var running = 0
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    init(width: Int) {
        self.width = max(1, width)
    }

    /// Waits for a free slot. Returns false, without taking a slot, when the
    /// calling task is cancelled first. Every `true` must be followed by `release()`.
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < width {
            running += 1
            return true
        }
        nextID &+= 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            // The slot passes straight to the newest waiter; `running` is unchanged.
            waiters.removeLast().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Loads thumbnails and full-screen photos away from the main thread: memory
/// first, then the disk cache, then decoding the original. Only a few files
/// decode at once, and work for a cell that has scrolled away is dropped before
/// it starts. Previously every cell passed in a fast scroll started its own
/// decode, which could not be cancelled and kept the screen's cells waiting.
enum MediaThumbnailLoader {
    /// Grid cells, list rows and the playback queue.
    static let thumbnailDimension = 320
    /// Full-screen photo pages.
    static let photoDimension = 2560

    private static let diskSlots = ImageWorkLimiter(width: 2)
    private static let thumbnailSlots = ImageWorkLimiter(width: 3)
    private static let photoSlots = ImageWorkLimiter(width: 2)

    static func image(for item: MediaItem, at url: URL, maxDimension: Int = thumbnailDimension) async -> UIImage? {
        let key = ThumbnailStore.key(for: item, url: url, maxDimension: maxDimension)
        let store = ThumbnailStore.shared
        if let image = store.memoryImage(forKey: key, maxDimension: maxDimension) { return image }
        if store.isUnreadable(key) || Task.isCancelled { return nil }
        let usesDisk = maxDimension <= ThumbnailStore.diskDimensionLimit
        let decodeSlots = usesDisk ? MediaThumbnailLoader.thumbnailSlots : MediaThumbnailLoader.photoSlots
        let diskSlots = MediaThumbnailLoader.diskSlots
        let work = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if usesDisk {
                guard await diskSlots.acquire() else { return nil }
                let cached = store.diskImage(forKey: key)
                await diskSlots.release()
                if let cached { return cached }
            }
            guard await decodeSlots.acquire() else { return nil }
            // Another request may have finished the same image while this one waited.
            if let ready = store.memoryImage(forKey: key, maxDimension: maxDimension) {
                await decodeSlots.release()
                return ready
            }
            let generated = await MediaThumbnailLoader.generate(item: item, url: url, maxDimension: maxDimension)
            await decodeSlots.release()
            if usesDisk, let generated { store.storeOnDisk(generated, forKey: key) }
            return generated
        }
        let image = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if let image {
            store.storeInMemory(image, forKey: key, maxDimension: maxDimension)
        } else if item.kind == .image, !work.isCancelled {
            store.markUnreadable(key)
        }
        return image
    }

    private static func generate(item: MediaItem, url: URL, maxDimension: Int) async -> UIImage? {
        if item.kind == .image {
            // ImageIO scales while it decodes; the source keeps no full-size copy.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        // Many clips open on a black fade; take the poster slightly after the start.
        let poster = CMTime(seconds: MediaPosterPolicy.time(duration: item.duration), preferredTimescale: 600)
        if let result = try? await generator.image(at: poster) {
            return UIImage(cgImage: result.image)
        }
        // A very short clip may have no frame at the poster time.
        if let result = try? await generator.image(at: .zero) {
            return UIImage(cgImage: result.image)
        }
        // The software decoder is slow; skip it for a cell that is already gone.
        guard !Task.isCancelled else { return nil }
        return await MPVMediaProbe.shared.inspect(item, at: url)?.image
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    let url: URL
    var showsDuration = true
    @State private var image: UIImage?
    @State private var loadedKey: String?

    private var key: String {
        ThumbnailStore.key(for: item, url: url, maxDimension: MediaThumbnailLoader.thumbnailDimension)
    }

    var body: some View {
        let currentKey = key
        // A synchronous memory lookup keeps reappearing rows from flashing a placeholder.
        let shown = (loadedKey == currentKey ? image : nil)
            ?? ThumbnailStore.shared.memoryImage(forKey: currentKey, maxDimension: MediaThumbnailLoader.thumbnailDimension)
            ?? image
        MediaThumbnailArtwork(item: item, image: shown, showsDuration: showsDuration)
            .task(id: currentKey) {
                if loadedKey == currentKey, image != nil { return }
                if let cached = ThumbnailStore.shared.memoryImage(forKey: currentKey,
                                                                  maxDimension: MediaThumbnailLoader.thumbnailDimension) {
                    image = cached
                    loadedKey = currentKey
                    return
                }
                // Cancelled when the cell scrolls away; queued work for it is dropped.
                let result = await MediaThumbnailLoader.image(for: item, at: url)
                guard !Task.isCancelled else { return }
                image = result
                loadedKey = currentKey
            }
    }
}

/// The slot, rather than the decoded image, owns the layout size. Overlay
/// content cannot enlarge a List row or a photo-grid cell when a tall image
/// arrives asynchronously.
struct MediaThumbnailArtwork: View {
    let item: MediaItem
    let image: UIImage?
    var showsDuration = true

    var body: some View {
        Rectangle()
            .fill(Theme.surface)
            .overlay {
                // An overlay is offered the slot's size and the final clip trims the
                // filled image, without a GeometryReader in every cell.
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(AppTypography.title2)
                        .foregroundStyle(Theme.subtle)
                }
            }
            .overlay(alignment: .bottom) {
                // Watched share of a video with a remembered position.
                if item.kind == .video, let fraction = item.watchedFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.55))
                            Rectangle().fill(Theme.accent).frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video && showsDuration {
                    Text(item.displayDuration)
                        .font(AppTypography.numeric(.caption2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: Capsule())
                        .padding(.horizontal, 4)
                        .padding(.bottom, item.watchedFraction == nil ? 4 : 7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
