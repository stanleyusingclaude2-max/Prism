import SwiftUI

@MainActor
struct PlaybackGestureGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            guideContent
                .background(Theme.bg)
                .navigationTitle("操作手势")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .font(AppTypography.body)
                            .accessibilityIdentifier("player.gestureGuide.done")
                    }
                }
        }
        .font(AppTypography.body)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("player.gestureGuide")
    }

    private var guideContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("用手势浏览片段，用逐帧找到细节。")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Theme.muted)
                instructionGroup("画面手势", instructions: Self.screenInstructions)
                instructionGroup("精确控制", instructions: Self.controlInstructions)
                instructionGroup("更多", instructions: Self.moreInstructions)
                Text("画面手势也适用于视频周围的黑边。请避开按钮，从画面中间开始拖动或滑动；屏幕边缘的手势由 iOS 处理。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .accessibilityIdentifier("player.gestureGuide.scroll")
    }

    private func instructionGroup(_ title: String, instructions: [Instruction]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTypography.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(instructions) { instruction in
                instructionRow(instruction)
            }
        }
    }

    private func instructionRow(_ instruction: Instruction) -> some View {
        HStack(alignment: .top, spacing: 14) {
            instructionIcon(instruction)
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(instruction.title).font(AppTypography.subheadline.weight(.semibold))
                Text(instruction.detail)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func instructionIcon(_ instruction: Instruction) -> some View {
        if instruction.id == "frames" {
            HStack(spacing: 2) {
                DesignIcon(name: "IconFrameprev", size: 18)
                DesignIcon(name: "IconFramenext", size: 18)
            }
        } else {
            Image(systemName: instruction.symbol)
                .font(AppTypography.title3)
        }
    }

    private struct Instruction: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    private static let screenInstructions: [Instruction] = [
        .init(id: "seek", symbol: "arrow.left.and.right", title: "左右拖动 · 快退／快进",
              detail: "在视频画面任意位置向右拖动快进，向左拖动快退，轻微斜向起手也可识别。画面实时预览；松手后恢复拖动前的播放或暂停状态。"),
        .init(id: "switch", symbol: "arrow.up.and.down", title: "上下滑动 · 切换视频",
              detail: "向上滑切到下一个视频，向下滑回到上一个，顺序与进入播放器时的列表一致。"),
        .init(id: "tap", symbol: "hand.tap", title: "轻点 · 显示／隐藏控件",
              detail: "轻点画面立即切换播放控件。播放时无操作 3 秒后自动隐藏；暂停时不会自动隐藏，也可以轻点收起。"),
        .init(id: "zoom", symbol: "hand.pinch", title: "双指捏合 · 放大局部",
              detail: "两指张开放大，最多 4 倍，放大的是手指所在的位置。放大后单指拖动查看其他区域；捏回原大小或点“还原画面”恢复完整画面。播放状态保持不变。"),
        .init(id: "hold", symbol: "hand.point.up.left", title: "长按 · 临时 2 倍速",
              detail: "按住画面约 0.35 秒，临时以 2 倍速播放。松手恢复原先倍速；原来暂停的视频会恢复暂停。按住后横向拖动，可切换为定位视频。")
    ]

    private static let controlInstructions: [Instruction] = [
        .init(id: "frames", symbol: "", title: "逐帧 · 查看前后单帧",
              detail: "轻点胶片箭头按钮，暂停并查看上一帧或下一帧。长按按钮可连续逐帧。"),
        .init(id: "timeline", symbol: "slider.horizontal.3", title: "时间轴 · 精确定位",
              detail: "拖动底部时间轴，实时查看目标画面。松手后精确定位，并恢复拖动前的播放或暂停状态。播放时只显示到秒，暂停后显示到毫秒。"),
        .init(id: "speed", symbol: "speedometer", title: "倍速 · 左下角",
              detail: "轻点左下角的倍速按钮，直接选择 0.25× 到 2×。不是 1× 时按钮会高亮。"),
        .init(id: "landscape", symbol: "iphone.landscape", title: "横屏 · 横向视频",
              detail: "横向视频右下角有横屏按钮，轻点后转为横屏播放，再点一次恢复。竖向视频竖着拿手机就是全屏。iPad 和展开的 iPhone Duo 屏幕够宽，不显示这个按钮。"),
        .init(id: "lock", symbol: "lock", title: "锁定 · 防止误触",
              detail: "在“更多”中选择“锁定触控”，画面手势和播放控件都会停用。轻点屏幕会显示“解锁”按钮。")
    ]

    private static let moreInstructions: [Instruction] = [
        .init(id: "resume", symbol: "clock.arrow.circlepath", title: "断点续播",
              detail: "15 秒以上的视频会记住上次停下的位置，再次打开时从那里继续，顶部提示中可以选择从头播放。看到结尾后会从头开始。"),
        .init(id: "end", symbol: "repeat", title: "播完后",
              detail: "可选择停在末尾、单条循环或自动播放下一个。"),
        .init(id: "loop", symbol: "arrow.left.and.right", title: "A–B 区间循环",
              detail: "在“更多”中选择“A–B 区间循环”，播放器底部会出现 A、B 按钮。拖动或逐帧到起点点 A，再到终点点 B，就会循环这一段，进度条上会标出区间。"),
        .init(id: "queue", symbol: "list.bullet", title: "当前列表",
              detail: "按媒体库中看到的顺序选择上一个、下一个或任意一个视频。"),
        .init(id: "capture", symbol: "camera", title: "保存当前帧",
              detail: "暂停在当前画面，可将 PNG 存到相册、文件或分享。")
    ]
}
