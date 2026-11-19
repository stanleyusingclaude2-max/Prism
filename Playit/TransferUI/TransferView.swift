import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TransferView: View {
    @ObservedObject var store: TransferStore
    @ObservedObject var library: LibraryStore
    @State private var showsFileImporter = false
    @State private var showsUSBHelp = false
    @State private var copiedAddress = false
    @State private var lastReceived: Int64 = 0
    @State private var lastSample = Date()
    @State private var bytesPerSecond: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    receiverCard
                    if !store.uploads.isEmpty { transferQueue }
                    otherMethods
                    Text("手机可用空间 " + MediaFormatting.bytes(store.freeBytes))
                        .font(AppTypography.numeric(.caption)).foregroundStyle(Theme.subtle)
                    if library.isImporting {
                        ProgressView(library.importProgress).font(AppTypography.caption).tint(Theme.accent)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("传文件")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { store.refreshCapacity() }
            .onReceive(store.$uploads) { uploads in updateSpeed(uploads) }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showsUSBHelp) { usbHelp }
            .alert("无法完成传输", isPresented: Binding(get: { store.errorMessage != nil || library.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil; library.errorMessage = nil } })) {
                Button("知道了", role: .cancel) { store.errorMessage = nil; library.errorMessage = nil }
            } message: { Text(store.errorMessage ?? library.errorMessage ?? "") }
        }
        .foregroundStyle(Theme.text)
        .font(AppTypography.body)
    }

    /// One instruction at a time: off explains how to start; on shows the address
    /// as the largest thing on the page, because it has to be typed on a computer.
    private var receiverCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DesignIcon(name: "IconWifi", size: 26).foregroundStyle(store.isRunning ? Theme.accent : Theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wi-Fi 传输").font(AppTypography.subheadline.weight(.semibold))
                    Text(store.isRunning ? "传输时请让 Prism 留在前台" : "电脑和手机连同一个 Wi-Fi")
                        .font(AppTypography.caption).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Toggle("Wi-Fi 传输", isOn: Binding(get: { store.isRunning }, set: { $0 ? store.start() : store.stop() }))
                    .labelsHidden().tint(Theme.accent).accessibilityIdentifier("transfer.toggle")
            }
            if let address = store.address {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在电脑浏览器地址栏输入").font(AppTypography.caption).foregroundStyle(Theme.muted)
                    HStack(alignment: .center, spacing: 8) {
                        Text(displayAddress(address))
                            .font(AppTypography.numeric(.title2, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                            .accessibilityLabel(address)
                            .accessibilityIdentifier("transfer.address")
                        Spacer(minLength: 4)
                        Button {
                            UIPasteboard.general.string = address
                            copiedAddress = true
                        } label: { DesignIcon(name: copiedAddress ? "IconCheck" : "IconCopy", size: 20) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(copiedAddress ? "地址已复制" : "复制完整传输地址")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: address) { _, _ in copiedAddress = false }
            } else if store.isRunning {
                ProgressView("正在开启接收…").font(AppTypography.caption).tint(Theme.accent)
            } else {
                Text("开启后，在电脑浏览器输入这里显示的地址，把视频或图片拖进网页即可上传。")
                    .font(AppTypography.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if store.isRunning || store.statusMessage != TransferStore.idleMessage {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(store.isRunning ? Theme.accent : Theme.subtle).frame(width: 6, height: 6).padding(.top, 5)
                    Text(store.statusMessage).font(AppTypography.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Browsers accept "192.168.1.5:8080" without the scheme or trailing slash.
    private func displayAddress(_ address: String) -> String {
        var value = address
        if value.hasPrefix("http://") { value.removeFirst("http://".count) }
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private var transferQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.uploads.contains(where: { $0.state == .receiving }) ? "正在接收" : "最近传输")
                    .font(AppTypography.subheadline.weight(.medium))
                Spacer()
                if bytesPerSecond > 0 {
                    Text(MediaFormatting.bytes(Int64(bytesPerSecond)) + "/s").font(AppTypography.numeric(.caption)).foregroundStyle(Theme.accent)
                }
            }
            ForEach(store.uploads) { upload in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        DesignIcon(name: upload.state == .completed ? "IconCheck" : "IconFile", size: 22)
                            .foregroundStyle(upload.state == .completed ? Theme.accent : Theme.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(upload.name).font(AppTypography.subheadline).lineLimit(2)
                            Text(upload.state == .completed ? "已存入媒体库" : upload.state == .failed ? upload.errorMessage ?? "传输失败，请在电脑重试" : MediaFormatting.bytes(upload.receivedBytes) + " / " + MediaFormatting.bytes(upload.totalBytes))
                                .font(AppTypography.caption).foregroundStyle(upload.state == .failed ? Theme.danger : Theme.muted)
                        }
                        Spacer(minLength: 8)
                        if upload.state == .receiving {
                            Text("\(Int(upload.progress * 100))%").font(AppTypography.numeric(.caption)).foregroundStyle(Theme.accent)
                        }
                    }
                    if upload.state == .receiving { ProgressView(value: upload.progress).tint(Theme.accent) }
                }
                .padding(12)
                .background(upload.state == .receiving ? Theme.surface : Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var otherMethods: some View {
        HStack(spacing: 12) {
            Button { showsFileImporter = true } label: {
                transferMethodLabel("从文件导入", icon: "IconFolder")
            }.accessibilityIdentifier("transfer.fileImport")
            Button { showsUSBHelp = true } label: {
                transferMethodLabel("USB 传输", icon: "IconTransfer")
            }.accessibilityIdentifier("transfer.usbHelp")
        }
        .buttonStyle(TransferMethodButtonStyle())
    }

    private func transferMethodLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            DesignIcon(name: icon, size: 20).foregroundStyle(Theme.muted)
            Text(title)
                .font(AppTypography.subheadline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var usbHelp: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    Text("1. 使用数据线连接 iPhone，并在手机上选择“信任”。")
                    Text("2. 在 Finder 左侧选择 iPhone，打开“文件”。")
                    Text("3. 将视频或图片拖入 Prism，完成后回到媒体库。")
                }
                Section("Windows") {
                    Text("在 Apple Devices（或 iTunes）的“文件共享”中选择 Prism，再添加视频或图片。")
                }
                Section {
                    Text("也可以在 iPhone 的“文件”App →“我的 iPhone”→ Prism 中整理文件夹。")
                }
            }
            .navigationTitle("USB 传文件").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsUSBHelp = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func updateSpeed(_ uploads: [TransferUpload]) {
        let now = Date()
        let total = uploads.reduce(Int64(0)) { $0 + $1.receivedBytes }
        guard uploads.contains(where: { $0.state == .receiving }) else {
            bytesPerSecond = 0; lastReceived = total; lastSample = now; return
        }
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed >= 0.5 {
            bytesPerSecond = Double(max(0, total - lastReceived)) / elapsed
            lastReceived = total; lastSample = now
        }
    }
}

private struct TransferMethodButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(configuration.isPressed ? Theme.raised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
