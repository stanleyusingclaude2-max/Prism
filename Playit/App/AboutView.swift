import SwiftUI

/// The app version and the open-source notices that ship inside the app.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short)（\(build)）"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("版本") {
                        Text(version).font(AppTypography.numeric(.body)).foregroundStyle(Theme.muted)
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    licenseLink("第三方组件说明", resource: "THIRD-PARTY-NOTICES")
                    licenseLink("MPVKit · libmpv · FFmpeg（LGPL）", resource: "MPVKit-LICENSE")
                    licenseLink("D-DIN 字体（SIL OFL 1.1）", resource: "D-DIN-OFL")
                } header: {
                    Text("开源许可").font(AppTypography.caption)
                } footer: {
                    Text("Prism 的播放内核使用以上开源组件。对应源码的获取地址见“第三方组件说明”。")
                        .font(AppTypography.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("关于 Prism")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("about.done")
                }
            }
        }
        .font(AppTypography.body)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func licenseLink(_ title: String, resource: String) -> some View {
        NavigationLink {
            LicenseTextView(title: title, resource: resource)
        } label: {
            Text(title)
        }
        .listRowBackground(Theme.surface)
    }
}

private struct LicenseTextView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "未找到许可文本。"
        }
        return content
    }
}
