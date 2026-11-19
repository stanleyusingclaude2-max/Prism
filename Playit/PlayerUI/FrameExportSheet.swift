import ImageIO
import Photos
import SwiftUI
import UIKit

struct FramePresentation: Identifiable {
    let url: URL
    var id: URL { url }
}

@MainActor
struct FrameExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?
    @State private var exportingToFiles = false
    @State private var savingPhoto = false
    @State private var savedPhoto = false
    @State private var photoError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("保存的画面")
                    }
                    // Saving to Photos is the common case, so it is the primary action.
                    Button(action: saveToPhotos) {
                        Label(savedPhoto ? "已保存到相册" : savingPhoto ? "正在保存…" : "保存到相册",
                              systemImage: savedPhoto ? "checkmark" : "photo")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(savingPhoto || savedPhoto)
                    .accessibilityIdentifier("player.frame.savePhotos")
                    HStack(spacing: 12) {
                        Button { exportingToFiles = true } label: {
                            Label("存储到文件", systemImage: "folder")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("player.frame.saveFiles")
                        ShareLink(item: url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("player.frame.share")
                    }
                    if let photoError {
                        Text(photoError).font(AppTypography.caption).foregroundStyle(Theme.danger)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("当前帧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("player.frame.done")
                }
            }
        }
        .font(AppTypography.body)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $exportingToFiles) { FrameDocumentExporter(url: url) }
        .task {
            preview = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
    }

    private func saveToPhotos() {
        savingPhoto = true
        photoError = nil
        Task {
            defer { savingPhoto = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                photoError = "请在设置中允许 Prism 添加照片。"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
                savedPhoto = true
                Haptics.success()
            } catch {
                photoError = error.localizedDescription
            }
        }
    }
}

private struct FrameDocumentExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
