import Foundation

struct PlaybackTrack: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let language: String?
    let codec: String?

    var displayName: String {
        var parts = [name]
        if let language, !language.isEmpty { parts.append(language) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        return parts.joined(separator: " · ")
    }
}
