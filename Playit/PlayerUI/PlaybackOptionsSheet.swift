import SwiftUI
import PlayitCore

/// The player's "更多" sheet. Speed lives on the player itself; this sheet holds
/// the less frequent choices. Text stays white; the accent marks icons only.
@MainActor
struct PlaybackOptionsSheet: View {
    @ObservedObject var controller: PlaybackController
    let entry: PlaybackEntry
    let entries: [PlaybackEntry]
    let index: Int
    @Binding var endAction: PlaybackEndAction
    @Binding var subtitleScale: Double
    let externalSaveState: ExternalSaveState
    let onSaveExternal: () -> Void
    let onSelect: (Int) -> Void
    let onCapture: () -> Void
    let onEditABLoop: () -> Void
    let onImportSubtitle: () -> Void
    let onLock: () -> Void
    let onShowGestureGuide: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var item: MediaItem { entry.item }

    var body: some View {
        NavigationStack {
            Form {
                playbackSection
                frameSection
                tracksSection
                Section {
                    actionRow("锁定触控", systemImage: "lock", identifier: "player.lock",
                              enabled: controller.isReady, action: onLock)
                    ShareLink(item: entry.url) {
                        rowLabel("分享视频", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("player.share")
                    .listRowBackground(Theme.surface)
                }
                fileSection
                Section {
                    actionRow("操作手势", systemImage: "hand.draw", identifier: "player.openGestureGuide",
                              action: onShowGestureGuide)
                }
            }
            .font(AppTypography.body)
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .font(AppTypography.body)
                        .accessibilityIdentifier("player.settingsDone")
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var playbackSection: some View {
        Section {
            Picker(selection: $endAction) {
                ForEach(PlaybackEndAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            } label: {
                rowLabel("播完后", systemImage: "repeat")
            }
            .pickerStyle(.menu)
            .disabled(!controller.isReady)
            .accessibilityIdentifier("player.endAction")
            .listRowBackground(Theme.surface)

            actionRow("A–B 区间循环", systemImage: "arrow.left.and.right", detail: abSummary,
                      identifier: "player.abLoop", enabled: controller.canMarkLoop || controller.loopStart != nil,
                      action: onEditABLoop)

            if entries.count > 1 {
                NavigationLink {
                    PlaybackQueueView(entries: entries, index: index, onSelect: onSelect)
                } label: {
                    rowLabel("当前列表", systemImage: "list.bullet", detail: "\(index + 1) / \(entries.count)")
                }
                .accessibilityIdentifier("player.queue")
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("播放").font(AppTypography.caption)
        } footer: {
            if entries.count > 1 {
                Text("在画面上上下滑动，可切换上一个或下一个视频。").font(AppTypography.caption)
            }
        }
    }

    private var frameSection: some View {
        Section {
            actionRow("保存当前帧", systemImage: "camera", identifier: "player.captureFrame",
                      enabled: controller.canExportFrame, action: onCapture)
            if entry.isExternal {
                actionRow(externalSaveState.title, systemImage: externalSaveState.icon,
                          identifier: "player.saveExternal", enabled: externalSaveState.canSave,
                          action: onSaveExternal)
                if case .failed(let message) = externalSaveState {
                    Text(message).font(AppTypography.caption).foregroundStyle(Theme.danger)
                        .listRowBackground(Theme.surface)
                }
            }
        }
    }

    private var tracksSection: some View {
        Section {
            if controller.audioTracks.isEmpty {
                LabeledContent {
                    Text("无音轨").foregroundStyle(Theme.muted)
                } label: {
                    rowLabel("音轨", systemImage: "speaker.wave.2")
                }
                .listRowBackground(Theme.surface)
            } else {
                Picker(selection: Binding(
                    get: { selectedAudioTrack },
                    set: { controller.selectAudioTrack($0) }
                )) {
                    ForEach(controller.audioTracks) { track in
                        Text(track.displayName).tag(track.id)
                    }
                } label: {
                    rowLabel("音轨", systemImage: "speaker.wave.2")
                }
                .pickerStyle(.menu)
                .disabled(!controller.isReady)
                .accessibilityIdentifier("player.audioTrack")
                .listRowBackground(Theme.surface)
            }

            Picker(selection: Binding(
                get: { selectedSubtitleTrack },
                set: { controller.selectSubtitleTrack($0 == -1 ? nil : $0) }
            )) {
                Text("关闭字幕").tag(-1)
                ForEach(controller.subtitleTracks) { track in
                    Text(track.displayName).tag(track.id)
                }
            } label: {
                rowLabel("字幕", systemImage: "captions.bubble")
            }
            .pickerStyle(.menu)
            .disabled(!controller.isReady)
            .accessibilityIdentifier("player.subtitleTrack")
            .listRowBackground(Theme.surface)

            Picker(selection: $subtitleScale) {
                ForEach(SubtitleSize.allCases) { size in
                    Text(size.title).tag(size.scale)
                }
            } label: {
                rowLabel("字幕大小", systemImage: "textformat.size")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("player.subtitleSize")
            .listRowBackground(Theme.surface)

            actionRow("导入字幕文件", systemImage: "doc.badge.plus", identifier: "player.importSubtitle",
                      enabled: controller.isReady, action: onImportSubtitle)
        } header: {
            Text("音轨与字幕").font(AppTypography.caption)
        }
    }

    private var fileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.filename)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(fileDetails)
                    .font(AppTypography.numeric(.caption))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.surface)
        } header: {
            Text("文件信息").font(AppTypography.caption)
        }
    }

    private func actionRow(_ title: String, systemImage: String, detail: String? = nil, identifier: String,
                           enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, systemImage: systemImage, detail: detail)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
        .listRowBackground(Theme.surface)
    }

    private func rowLabel(_ title: String, systemImage: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(title).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.accent)
            }
            if let detail {
                Spacer(minLength: 8)
                Text(detail)
                    .font(AppTypography.numeric(.subheadline))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private var abSummary: String {
        if let start = controller.loopStart, let end = controller.loopEnd {
            return MediaFormatting.time(start, milliseconds: true) + "–" + MediaFormatting.time(end, milliseconds: true)
        }
        if let start = controller.loopStart {
            return "A " + MediaFormatting.time(start, milliseconds: true)
        }
        return "未设置"
    }

    private var selectedAudioTrack: Int {
        if let selected = controller.selectedAudioTrackID,
           controller.audioTracks.contains(where: { $0.id == selected }) { return selected }
        return controller.audioTracks.first?.id ?? -1
    }

    private var selectedSubtitleTrack: Int {
        guard let selected = controller.selectedSubtitleTrackID,
              controller.subtitleTracks.contains(where: { $0.id == selected }) else { return -1 }
        return selected
    }

    private var fileDetails: String {
        var parts: [String] = []
        let duration = controller.duration > 0 ? controller.duration : item.duration ?? 0
        if duration.isFinite, duration > 0 { parts.append(MediaFormatting.time(duration)) }

        let width = controller.videoWidth > 0 ? controller.videoWidth : item.pixelWidth ?? 0
        let height = controller.videoHeight > 0 ? controller.videoHeight : item.pixelHeight ?? 0
        if width > 0, height > 0 { parts.append("\(width) × \(height)") }
        if controller.nominalFPS.isFinite, controller.nominalFPS > 0 {
            parts.append(String(format: "%g fps", controller.nominalFPS))
        }
        parts.append(MediaFormatting.bytes(item.byteCount))
        return parts.joined(separator: " · ")
    }
}

enum ExternalSaveState {
    case available, saving, saved, failed(String)

    var canSave: Bool {
        switch self {
        case .available, .failed: return true
        case .saving, .saved: return false
        }
    }

    var title: String {
        switch self {
        case .available: return "保存到媒体库"
        case .saving: return "正在保存…"
        case .saved: return "已保存到媒体库"
        case .failed: return "重试保存到媒体库"
        }
    }

    var icon: String {
        if case .saved = self { return "checkmark" }
        return "square.and.arrow.down"
    }
}
