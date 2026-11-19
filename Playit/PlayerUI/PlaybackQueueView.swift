import SwiftUI
import PlayitCore

struct PlaybackQueueView: View {
    let entries: [PlaybackEntry]
    let index: Int
    let onSelect: (Int) -> Void

    var body: some View {
        List {
            Section {
                Button { onSelect(index - 1) } label: {
                    Label("上一个视频", systemImage: "chevron.up")
                }
                .disabled(index == 0)
                .accessibilityIdentifier("player.queue.previous")
                .listRowBackground(Theme.surface)
                Button { onSelect(index + 1) } label: {
                    Label("下一个视频", systemImage: "chevron.down")
                }
                .disabled(index + 1 >= entries.count)
                .accessibilityIdentifier("player.queue.next")
                .listRowBackground(Theme.surface)
            }
            Section("第 \(index + 1) 个，共 \(entries.count) 个视频") {
                ForEach(entries.indices, id: \.self) { position in
                    let entry = entries[position]
                    Button { onSelect(position) } label: {
                        HStack(spacing: 12) {
                            MediaThumbnail(item: entry.item, url: entry.url, showsDuration: false)
                                .frame(width: 64, height: 40)
                                .clipped()
                                .fixedSize()
                            Text(entry.item.displayTitle)
                                .font(AppTypography.subheadline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            if position == index {
                                DesignIcon(name: "IconPlay", size: 16)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(Theme.text)
                    }
                    .disabled(position == index)
                    .accessibilityValue(position == index ? "当前视频" : "")
                    .accessibilityIdentifier("player.queue." + entry.id)
                    .listRowBackground(position == index ? Theme.raised : Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("当前列表")
        .navigationBarTitleDisplayMode(.inline)
    }
}
