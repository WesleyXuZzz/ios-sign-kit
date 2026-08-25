import SwiftUI

struct LiveDeployOutputPanel: View {
    enum Layout {
        static let minimumContentHeight: CGFloat = 190
        static let idealContentHeight: CGFloat = 250
        static let maximumContentHeight: CGFloat = 280
    }

    static let waitingMessage = "等待续签日志输出…"

    let logText: String
    let onExpand: () -> Void

    @State private var autoScrollEnabled = true

    private static let tailAnchorID = "live-deploy-output-tail"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(ColorTokens.Log.border)
                .frame(height: 1)
                .accessibilityHidden(true)

            logBody
        }
        .background(ColorTokens.BG.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: SpacingTokens.Radius.card,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: SpacingTokens.Radius.card,
                style: .continuous
            )
            .strokeBorder(ColorTokens.Border.subtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    static func displayedText(for logText: String) -> String {
        let trimmed = logText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? waitingMessage : trimmed
    }

    private var displayedLogText: String {
        Self.displayedText(for: logText)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ColorTokens.Text.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            Text("实时输出")
                .font(TypeTokens.cardTitle)
                .foregroundStyle(ColorTokens.Text.primary)

            HStack(spacing: 6) {
                Circle()
                    .fill(ColorTokens.Accent.renew)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text("正在更新")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Accent.renew)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("日志正在实时更新")

            Spacer(minLength: SpacingTokens.md)

            Button {
                onExpand()
            } label: {
                Label(
                    "展开",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
            }
            .buttonStyle(RenewalButtonStyle(kind: .text))
            .help("在浮层中查看完整续签日志")

            Toggle("自动滚动", isOn: $autoScrollEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .help("有新输出时自动滚动到日志末尾")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayedLogText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(
                            logText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                                ? ColorTokens.Text.secondary
                                : ColorTokens.Log.text
                        )
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )

                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchorID)
                        .accessibilityHidden(true)
                }
                .padding(12)
            }
            .frame(
                minHeight: Layout.minimumContentHeight,
                idealHeight: Layout.idealContentHeight,
                maxHeight: Layout.maximumContentHeight
            )
            .background(ColorTokens.Log.background)
            .onAppear {
                scrollToTail(using: proxy)
            }
            .onChange(of: displayedLogText) { _, _ in
                guard autoScrollEnabled else { return }
                scrollToTail(using: proxy)
            }
            .onChange(of: autoScrollEnabled) { _, enabled in
                guard enabled else { return }
                scrollToTail(using: proxy)
            }
        }
    }

    private func scrollToTail(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.tailAnchorID, anchor: .bottom)
        }
    }
}
