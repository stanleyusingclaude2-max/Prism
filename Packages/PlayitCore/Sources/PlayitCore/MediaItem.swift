import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case video
    case image

    public static func classify(fileExtension: String) -> MediaKind? {
        let value = fileExtension.lowercased()
        if videoExtensions.contains(value) { return .video }
        if imageExtensions.contains(value) { return .image }
        return nil
    }

    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "mts", "m2ts",
        "mpg", "mpeg", "wmv", "flv", "3gp"
    ]

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"
    ]
}

public struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public var filename: String
    public var kind: MediaKind
    public var byteCount: Int64
    public var importedAt: Date
    public var modifiedAt: Date
    public var duration: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Where playback stopped last time. Nil means the next playback starts at 0.
    public var playbackPosition: Double?
    public var lastPlayedAt: Date?

    public init(
        relativePath: String,
        filename: String? = nil,
        kind: MediaKind,
        byteCount: Int64 = 0,
        importedAt: Date = Date(),
        modifiedAt: Date = Date(),
        duration: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        playbackPosition: Double? = nil,
        lastPlayedAt: Date? = nil
    ) {
        self.relativePath = relativePath
        self.filename = filename ?? (relativePath as NSString).lastPathComponent
        self.kind = kind
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.modifiedAt = modifiedAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.playbackPosition = playbackPosition
        self.lastPlayedAt = lastPlayedAt
    }

    /// The watched share of a remembered position, for a progress line on thumbnails.
    public var watchedFraction: Double? {
        guard let playbackPosition, let duration, playbackPosition.isFinite, duration.isFinite,
              duration > 0, playbackPosition > 0 else { return nil }
        return min(max(playbackPosition / duration, 0), 1)
    }

    /// The filename without its extension, for titles where the format is noise.
    public var displayTitle: String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? filename : stem
    }

    public var folderPath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    public var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
}

public struct MediaFolder: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var relativePath: String { path }
    public var name: String
    public var mediaCount: Int
    public var videoCount: Int
    public var imageCount: Int

    public init(path: String, name: String? = nil, videoCount: Int = 0, imageCount: Int = 0) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.videoCount = videoCount
        self.imageCount = imageCount
        self.mediaCount = videoCount + imageCount
    }
}

public enum MediaLibraryError: LocalizedError, Equatable {
    case invalidPath
    case invalidName
    case unsupportedFile
    case fileNotFound
    case destinationExists(String)
    case sourceIsDestination
    case insufficientSpace

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "文件路径无效，无法访问媒体库之外的位置。"
        case .invalidName: return "名称不能为空，也不能包含斜杠或使用隐藏文件名称。"
        case .unsupportedFile: return "此文件不是支持导入的视频或图片。"
        case .fileNotFound: return "文件已被移动或删除，请刷新媒体库。"
        case .destinationExists(let name): return "目标位置已存在“\(name)”，请使用其他名称。"
        case .sourceIsDestination: return "文件已经在此位置。"
        case .insufficientSpace: return "手机剩余空间不足，请释放空间后重试。"
        }
    }
}
