import Combine
import Foundation
import UIKit

struct TransferUpload: Identifiable, Sendable {
    enum State: String, Sendable {
        case receiving, completed, failed
    }

    let id: UUID
    var name: String
    var receivedBytes: Int64
    let totalBytes: Int64
    var state: State
    var errorMessage: String?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

/// Own this object for the lifetime of the app. Its receiver performs all socket
/// and file work on a private serial queue; only throttled progress reaches UI.
@MainActor
final class TransferStore: ObservableObject {
    /// The resting message; the page hides the status line while it is shown.
    nonisolated static let idleMessage = "开启后，电脑浏览器即可传入视频和图片"

    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var statusMessage = TransferStore.idleMessage
    @Published private(set) var uploads: [TransferUpload] = []
    @Published var errorMessage: String?
    @Published private(set) var freeBytes: Int64 = 0

    private let rootURL: URL
    private let onImport: @MainActor () -> Void
    private var receiver: TransferReceiver?
    private var generation = UUID()
    private var backgroundObserver: NSObjectProtocol?

    init(rootURL: URL, onImport: @escaping @MainActor () -> Void) {
        self.rootURL = rootURL
        self.onImport = onImport
        refreshCapacity()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop()
                self.statusMessage = "已暂停接收：请回到 App 后重新开启传输"
            }
        }
    }

    deinit {
        receiver?.stop()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    func start() {
        guard !isRunning else { return }
        guard let ip = TransferLocalAddress.wifiIPv4() else {
            errorMessage = "请先让 iPhone 和电脑连接同一个 Wi-Fi。"
            statusMessage = "尚未连接可用的 Wi-Fi 网络"
            return
        }
        do { try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true) }
        catch {
            errorMessage = "无法访问媒体文件夹：\(error.localizedDescription)"
            return
        }
        generation = UUID()
        let currentGeneration = generation
        errorMessage = nil
        address = nil
        isRunning = true
        statusMessage = "正在开启 Wi-Fi 传输…"
        refreshCapacity()
        let receiver = TransferReceiver(rootURL: rootURL, address: ip) { [weak self] event in
            // Events originate from one serial receiver queue. Enqueue onto the
            // main queue in that order, so waiting cannot overwrite a later ready.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.receive(event)
            }
        }
        self.receiver = receiver
        receiver.start()
    }

    func stop() {
        generation = UUID()
        receiver?.stop()
        receiver = nil
        isRunning = false
        address = nil
        statusMessage = "Wi-Fi 传输已关闭"
        for index in uploads.indices where uploads[index].state == .receiving {
            uploads[index].state = .failed
            uploads[index].errorMessage = "传输已停止，请在电脑浏览器中重试。"
        }
        refreshCapacity()
    }

    func refreshCapacity() {
        freeBytes = TransferReceiver.availableBytes(at: rootURL)
    }

    private func receive(_ event: TransferReceiver.Event) {
        switch event {
        case .ready(let address):
            self.address = address
            statusMessage = "等待电脑上传"
        case .waiting(let message):
            address = nil
            statusMessage = message
        case .upload(let upload):
            if let index = uploads.firstIndex(where: { $0.id == upload.id }) {
                uploads[index] = upload
            } else {
                uploads.insert(upload, at: 0)
                if uploads.count > 50 {
                    // A session receives at most two files at once; retain recent
                    // completed entries without removing a live transfer.
                    while uploads.count > 50,
                          let last = uploads.lastIndex(where: { $0.state != .receiving }) {
                        uploads.remove(at: last)
                    }
                }
            }
            if upload.state == .receiving { statusMessage = "正在接收 \(upload.name)" }
            if upload.state == .completed {
                statusMessage = "\(upload.name) 已存入媒体库"
                refreshCapacity()
                onImport()
            }
            if upload.state == .failed {
                statusMessage = "传输中断，可在电脑浏览器中重试"
                refreshCapacity()
            }
        case .failed(let message):
            stop()
            errorMessage = message
            statusMessage = "Wi-Fi 传输未开启"
        }
    }
}
