import Foundation
import ImageIO
import Libmpv
import PlayitCore
import UIKit

/// AVFoundation covers native formats first. Only fallback requests use a
/// single software decoder and a shared cache, including metadata requests.
actor MPVMediaProbe {
    static let shared = MPVMediaProbe()

    struct Result {
        var duration: Double?
        var width: Int?
        var height: Int?
        var image: UIImage?
    }

    private final class Cached: NSObject {
        let result: Result
        init(_ result: Result) { self.result = result }
    }

    private let queue = DispatchQueue(label: "app.prism.media-probe", qos: .utility)
    private let cache = NSCache<NSString, Cached>()
    private var pending: [String: Task<Result?, Never>] = [:]
    private var failures: [String: TimeInterval] = [:]

    init() {
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func inspect(_ item: MediaItem, at url: URL) async -> Result? {
        let key = "\(url.path):\(item.modifiedAt.timeIntervalSince1970):\(item.byteCount)"
        if let cached = cache.object(forKey: key as NSString) { return cached.result }
        if let current = pending[key] { return await current.value }
        let now = ProcessInfo.processInfo.systemUptime
        if let retry = failures[key], retry > now { return nil }
        guard pending.count < 12 else { return nil }

        let task = Task.detached(priority: .utility) { [queue] () -> Result? in
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: Self.probe(url)) }
            }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result {
            let cost = result.image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            cache.setObject(Cached(result), forKey: key as NSString, cost: cost)
        } else {
            if failures.count >= 512 { failures = failures.filter { $0.value > now } }
            if failures.count >= 512 { failures.removeAll(keepingCapacity: true) }
            failures[key] = ProcessInfo.processInfo.systemUptime + 120
        }
        return result
    }

    private static func probe(_ url: URL) -> Result? {
        guard url.isFileURL, let player = mpv_create() else { return nil }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("PrismProbe-\(UUID().uuidString).png")
        defer {
            mpv_terminate_destroy(player)
            try? FileManager.default.removeItem(at: output)
        }
        let settings = [
            ("config", "no"), ("terminal", "no"), ("load-scripts", "no"),
            ("autoload-files", "no"), ("access-references", "no"), ("ytdl", "no"),
            ("vo", "null"), ("aid", "no"), ("sid", "no"), ("audio-display", "no"),
            ("hwdec", "no"), ("vd-lavc-threads", "2"), ("pause", "yes"),
            ("keep-open", "yes"), ("screenshot-sw", "yes"), ("screenshot-png-compression", "1")
        ]
        for (key, value) in settings {
            guard mpv_set_option_string(player, key, value) >= 0 else { return nil }
        }
        // Limit the image written by mpv before ImageIO applies its final size
        // cap, including files with non-square sample pixels.
        guard mpv_set_option_string(player, "vf", "lavfi=[scale=320:320:force_original_aspect_ratio=decrease]") >= 0,
              mpv_initialize(player) >= 0,
              sendMPVCommand(player, ["loadfile", url.path, "replace"], id: 1) >= 0 else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var result = Result()
        var requestedImage = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let event = mpv_wait_event(player, 0.1)?.pointee else { break }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED, MPV_EVENT_VIDEO_RECONFIG:
                readMetadata(into: &result, player: player)
            case MPV_EVENT_PLAYBACK_RESTART:
                readMetadata(into: &result, player: player)
                if !requestedImage, result.width != nil {
                    requestedImage = true
                    if sendMPVCommand(player, ["screenshot-to-file", output.path, "video"], id: 2) < 0 {
                        return result
                    }
                }
            case MPV_EVENT_COMMAND_REPLY:
                if event.reply_userdata == 1 && event.error < 0 { return nil }
                if event.reply_userdata == 2 {
                    if event.error >= 0,
                       let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceShouldCacheImmediately: true
                       ] as CFDictionary) {
                        result.image = UIImage(cgImage: image)
                    }
                    return result
                }
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return result.duration == nil && result.width == nil ? nil : result
            default: break
            }
        }
        return result.duration == nil && result.width == nil ? nil : result
    }

    private static func readMetadata(into result: inout Result, player: OpaquePointer) {
        var duration: Double = 0
        if mpv_get_property(player, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0,
           duration.isFinite, duration > 0 {
            result.duration = duration
        }
        guard let width = integer("video-params/w", player), width > 0,
              let height = integer("video-params/h", player), height > 0 else { return }
        let rotation = integer("video-params/rotate", player) ?? 0
        let sideways = rotation % 180 != 0
        result.width = sideways ? height : width
        result.height = sideways ? width : height
    }

    private static func integer(_ property: String, _ player: OpaquePointer) -> Int? {
        var value: Int64 = 0
        return mpv_get_property(player, property, MPV_FORMAT_INT64, &value) >= 0 ? Int(exactly: value) : nil
    }
}
