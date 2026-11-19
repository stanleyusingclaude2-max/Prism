import SwiftUI

/// A narrow visual track with a full 44-point touch target. Scrubbing previews
/// are rendered by the live video surface rather than a second thumbnail strip.
/// An A–B interval is drawn on the track itself.
struct PrecisionTimeline: View {
    let time: Double
    let duration: Double
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    let enabled: Bool
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let progress = fraction(time)
            let trackHeight: CGFloat = dragging ? 5 : 3
            let thumb: CGFloat = dragging ? 18 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: trackHeight)
                if let start = loopStart {
                    let startX = width * fraction(start)
                    if let end = loopEnd {
                        let endX = width * fraction(end)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent.opacity(0.3))
                            .frame(width: max(2, endX - startX), height: 11)
                            .offset(x: startX)
                        loopTick(at: endX, width: width)
                    }
                    loopTick(at: startX, width: width)
                }
                Capsule().fill(Theme.accent).frame(width: width * progress, height: trackHeight)
                Circle().fill(Theme.accent)
                    .frame(width: thumb, height: thumb)
                    .offset(x: min(max(0, width * progress - thumb / 2), max(0, width - thumb)))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled, duration > 0 else { return }
                    if !dragging { dragging = true; onBegin() }
                    onChange(position(value.location.x, width: width))
                }
                .onEnded { value in
                    guard dragging else { return }
                    dragging = false
                    onCommit(position(value.location.x, width: width))
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放进度")
            .accessibilityValue(accessibilityDescription)
            .accessibilityAdjustableAction { direction in
                guard enabled, duration > 0 else { return }
                let delta: Double = direction == .increment ? 1 : -1
                let value = min(max(0, time + delta), duration)
                onBegin(); onChange(value); onCommit(value)
            }
            .accessibilityIdentifier("player.timeline")
        }
        .frame(height: 44)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .onDisappear {
            if dragging { dragging = false; onCommit(time) }
        }
    }

    private func loopTick(at x: CGFloat, width: CGFloat) -> some View {
        Capsule()
            .fill(Theme.accent)
            .frame(width: 2, height: 15)
            .offset(x: min(max(0, x - 1), max(0, width - 2)))
            .accessibilityHidden(true)
    }

    private var accessibilityDescription: String {
        var value = MediaFormatting.time(time, milliseconds: true) + "，共 " + MediaFormatting.time(duration)
        if let loopStart, let loopEnd {
            value += "，区间循环 " + MediaFormatting.time(loopStart, milliseconds: true) +
                " 至 " + MediaFormatting.time(loopEnd, milliseconds: true)
        }
        return value
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard duration > 0, seconds.isFinite else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1))
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double {
        min(max(0, Double(x / width)), 1) * max(0, duration)
    }
}
