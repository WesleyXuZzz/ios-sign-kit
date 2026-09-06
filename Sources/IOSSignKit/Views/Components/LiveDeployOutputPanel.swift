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

    @Environment(\.interfaceStyle) private var interfaceStyle
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
        .clipShape(RoundedRectangle(cornerRadius: interfaceStyle.cardRadius))
        .interfaceSurface()
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("实时输出", systemImage: "terminal")
                    .font(TypeTokens.cardTitle)
                Spacer(minLength: 4)
                Text("正在更新")
                    .font(TypeTokens.auxiliary)
                    .foregroundStyle(ColorTokens.Accent.renew)
            }
            HStack {
                Toggle("自动滚动", isOn: $autoScrollEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(TypeTokens.caption)
                Spacer(minLength: 4)
                Button("展开", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
                    .buttonStyle(RenewalButtonStyle(kind: .text))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
