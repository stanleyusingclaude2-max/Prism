import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PlayitCore

/// The system picker grants access only to the items the user confirms.
struct PhotoImportPicker: UIViewControllerRepresentable {
    let onSelection: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelection: ([NSItemProvider]) -> Void

        init(onSelection: @escaping ([NSItemProvider]) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results.map(\.itemProvider))
        }
    }
}

extension NSItemProvider {
    /// The provider owns the temporary file. Copy it into the repository inside
    /// its callback, before the URL expires, without loading video bytes into RAM.
    func importPhotoSelection(into repository: MediaLibraryRepository, folder: String?) async throws {
        let mediaTypes = registeredTypeIdentifiers.compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        let type = mediaTypes.first { type in
            guard let ext = type.preferredFilenameExtension else { return false }
            return MediaKind.classify(fileExtension: ext) != nil
        } ?? mediaTypes.first
        guard let type else { throw MediaLibraryError.unsupportedFile }

        let suggestion = suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                let result = Result<Void, Error> {
                    if let error { throw error }
                    guard let url else { throw MediaLibraryError.fileNotFound }
                    let name = try Self.libraryFilename(for: url, suggestion: suggestion, type: type)
                    try repository.importFile(from: url, named: name, into: folder)
                }
                continuation.resume(with: result)
            }
        }
    }

    private static func libraryFilename(for url: URL, suggestion: String?, type: UTType) throws -> String {
        // Keep the actual delivered format if Photos converted the representation.
        let suggested = ((suggestion ?? "") as NSString).lastPathComponent
        let extensions: [String?] = [url.pathExtension, type.preferredFilenameExtension,
                                     (suggested as NSString).pathExtension]
        let ext = extensions.compactMap { $0 }
            .first { MediaKind.classify(fileExtension: $0) != nil }
        guard let ext else { throw MediaLibraryError.unsupportedFile }
        let candidate = suggested.isEmpty ? url.lastPathComponent : suggested
        let component = candidate as NSString
        let stem = MediaKind.classify(fileExtension: component.pathExtension) != nil || suggested.isEmpty
            ? component.deletingPathExtension : candidate
        let base = stem.isEmpty || stem.hasPrefix(".") ? "相册素材" : stem
        return base + "." + ext.lowercased()
    }
}
