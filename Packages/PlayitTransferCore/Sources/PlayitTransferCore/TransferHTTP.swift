import Foundation

/// The server accepts one HTTP/1.1 request per connection. Bodies are streamed
/// directly to disk by the receiver, never accumulated in this parser.
public struct TransferRequestHead: Equatable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let contentLength: Int64?

    public static let maximumHeaderBytes = 16_384

    public static func parse(_ bytes: Data) throws -> (head: Self, consumed: Int)? {
        let marker = Data([13, 10, 13, 10])
        guard let end = bytes.range(of: marker) else {
            if bytes.count > maximumHeaderBytes { throw TransferHTTPError.headersTooLarge }
            return nil
        }
        let length = bytes.distance(from: bytes.startIndex, to: end.upperBound)
        guard length <= maximumHeaderBytes else { throw TransferHTTPError.headersTooLarge }
        guard let raw = String(data: bytes[..<end.lowerBound], encoding: .utf8),
              !raw.contains("\0") else { throw TransferHTTPError.invalidRequest }
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw TransferHTTPError.invalidRequest }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1",
              ["GET", "HEAD", "POST"].contains(String(parts[0])),
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              !parts[1].contains("#") else { throw TransferHTTPError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else {
                throw TransferHTTPError.invalidRequest
            }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.contains("\r"), !value.contains("\n"),
                  headers[name] == nil else { throw TransferHTTPError.invalidRequest }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty,
              !host.contains("/"), !host.contains("@"),
              headers["transfer-encoding"] == nil else {
            throw TransferHTTPError.invalidRequest
        }
        var contentLength: Int64?
        if let field = headers["content-length"] {
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int64(field), number >= 0 else {
                throw TransferHTTPError.invalidRequest
            }
            contentLength = number
        }
        let head = Self(method: String(parts[0]), target: String(parts[1]),
                        headers: headers, contentLength: contentLength)
        return (head, length)
    }
}

public enum TransferHTTPError: Error, Equatable {
    case invalidRequest
    case headersTooLarge
    case invalidFilename
    case unsupportedFile
}

/// Read-only web routes; upload requests still require the exact session path.
public enum TransferWebRoute: Equatable, Sendable {
    case redirect(String)
    case page
    case status
    case font(String)
    case notFound
}

/// A path monitor can publish an initial unavailable snapshot while starting.
/// Stop an established receiver on loss, rather than cancelling it at startup.
public struct TransferNetworkContinuity: Sendable {
    private var hasUsableWiFi = false

    public init() {}

    public mutating func shouldStop(isSatisfied: Bool, hasOriginalAddress: Bool) -> Bool {
        if isSatisfied {
            guard hasOriginalAddress else { return true }
            hasUsableWiFi = true
            return false
        }
        return hasUsableWiFi
    }
}

public enum TransferFilePolicy {
    /// The first UUID field contains 32 random bits. Eight lowercase hex digits
    /// keep the temporary local-network address practical to type by hand.
    public static func makeSessionToken() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "mts", "m2ts",
        "mpg", "mpeg", "wmv", "flv", "3gp", "jpg", "jpeg", "png", "heic",
        "heif", "gif", "webp", "tif", "tiff", "bmp"
    ]

    public static func webRoute(target: String, token: String) -> TransferWebRoute {
        let root = "/\(token)/"
        if target == "/" || target == "/\(token)" { return .redirect(root) }
        switch target {
        case root: return .page
        case root + "status": return .status
        case root + "fonts/D-DIN.otf": return .font("D-DIN")
        case root + "fonts/D-DIN-Bold.otf": return .font("D-DIN-Bold")
        default: return .notFound
        }
    }

    public static func validatedFilename(_ input: String) throws -> String {
        let name = input.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.utf8.count <= 240,
              name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              (name as NSString).lastPathComponent == name else {
            throw TransferHTTPError.invalidFilename
        }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw TransferHTTPError.unsupportedFile
        }
        return name
    }

    /// The URL must identify this receiver session exactly; a query cannot
    /// change the target directory or access files outside the media root.
    public static func uploadFilename(target: String, token: String) throws -> String? {
        guard let components = URLComponents(string: target),
              components.scheme == nil, components.host == nil,
              components.percentEncodedPath == "/\(token)/upload" else { return nil }
        let names = (components.queryItems ?? []).filter { $0.name == "name" }
        guard names.count == 1, let name = names.first?.value else {
            throw TransferHTTPError.invalidFilename
        }
        return try validatedFilename(name)
    }

    public static func isSameOrigin(_ origin: String?, authority: String) -> Bool {
        guard let origin else { return false }
        return origin == "http://\(authority)"
    }
}
