import Foundation

public enum MediaSort: String, CaseIterable, Codable, Sendable {
    case name
    case importedAt
    case duration
    case fileSize
}

public enum SortDirection: String, CaseIterable, Codable, Sendable {
    case ascending
    case descending
}

public struct MediaQuery: Sendable {
    public var kind: MediaKind?
    public var search: String
    public var folderPath: String?
    public var sort: MediaSort
    public var direction: SortDirection

    public init(
        kind: MediaKind? = nil,
        search: String = "",
        folderPath: String? = nil,
        sort: MediaSort = .importedAt,
        direction: SortDirection = .descending
    ) {
        self.kind = kind
        self.search = search
        self.folderPath = folderPath
        self.sort = sort
        self.direction = direction
    }

    /// An empty folder selects the entire library. Otherwise descendants are
    /// included only at a path-component boundary, never by a loose prefix.
    public func apply(to items: [MediaItem]) -> [MediaItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (folderPath ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")

        return items.enumerated().filter { pair in
            let item = pair.element
            if let kind, item.kind != kind { return false }
            if !folder.isEmpty,
               item.folderPath != folder,
               !item.folderPath.hasPrefix(folder + "/") {
                return false
            }
            if !query.isEmpty,
               item.filename.range(
                   of: query,
                   options: [.caseInsensitive, .diacriticInsensitive],
                   locale: Locale.current
               ) == nil {
                return false
            }
            return true
        }.sorted { left, right in
            // Unknown durations stay at the end in both sort directions.
            if sort == .duration {
                let leftDuration = validDuration(left.element.duration)
                let rightDuration = validDuration(right.element.duration)
                if (leftDuration == nil) != (rightDuration == nil) {
                    return leftDuration != nil
                }
            }

            let ordering = compare(left.element, right.element)
            if ordering == .orderedSame {
                return left.offset < right.offset
            }
            return direction == .ascending
                ? ordering == .orderedAscending
                : ordering == .orderedDescending
        }.map(\.element)
    }

    private func compare(_ left: MediaItem, _ right: MediaItem) -> ComparisonResult {
        switch sort {
        case .name:
            return left.filename.compare(
                right.filename,
                options: [.numeric, .caseInsensitive, .diacriticInsensitive],
                locale: Locale.current
            )
        case .importedAt:
            return left.importedAt.compare(right.importedAt)
        case .fileSize:
            return scalarComparison(left.byteCount, right.byteCount)
        case .duration:
            guard let lhs = validDuration(left.duration),
                  let rhs = validDuration(right.duration) else {
                return .orderedSame
            }
            return scalarComparison(lhs, rhs)
        }
    }

    private func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func scalarComparison<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }
}
