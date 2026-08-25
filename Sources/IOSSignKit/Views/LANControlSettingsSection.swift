import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LANControlSettingsSection: View {
    private enum FocusedField: Hashable {
        case host
        case port
        case password
        case passwordConfirmation
    }

    private struct PairingSheet: Identifiable {
        let url: URL

        var id: String {
            url.absoluteString
        }
    }

    @ObservedObject var setupViewModel: SetupWizardViewModel
    @ObservedObject var server: LANControlServerController
    let issuePairingURL: () throws -> URL

    @State private var showsPassword = false
    @State private var pairingSheet: PairingSheet?
    @State private var copiedLink = false
    @State private var pairingError: String?
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            SettingsSectionCard(title: "服务", systemImage: "wifi") {
                settingRow(title: "启用局域网控制") {
                    Toggle("", isOn: $setupViewModel.lanControlEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)

                    Spacer(minLength: 0)

                    StatusPill(
                        text: server.status.title,
                        tone: serviceTone
                    )
                }

                if case .failed(let message) = server.status {
                    validationLabel(message)
                }
            }

            SettingsSectionCard(title: "连接", systemImage: "link") {
                VStack(alignment: .leading, spacing: 8) {
                    settingRow(title: "访问主机") {
                        TextField(
                            "例如 my-mac.local",
                            text: $setupViewModel.lanControlHost
                        )
                        .textFieldStyle(
                            LANControlFieldStyle(isFocused: focusedField == .host)
                        )
                        .focused($focusedField, equals: .host)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 280)
                    }

                    settingRow(title: "端口") {
                        TextField(
                            "51888",
                            text: $setupViewModel.lanControlPortText
                        )
                        .textFieldStyle(
                            LANControlFieldStyle(isFocused: focusedField == .port)
                        )
                        .focused($focusedField, equals: .port)
                        .frame(width: 100)
                    }

                    settingRow(title: "完整链接") {
                        Text(draftURLText)
                            .font(TypeTokens.mono)
                            .foregroundStyle(
                                setupViewModel.lanControlDraftURL == nil
                                    ? ColorTokens.Text.tertiary
                                    : ColorTokens.Text.primary
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(copiedLink ? "已复制" : "复制链接") {
                            copyAppliedLink()
                        }
                        .buttonStyle(RenewalButtonStyle(kind: .secondary))
                        .disabled(!canShareAppliedLink)

                        Button("生成一次性二维码", systemImage: "qrcode") {
                            showPairingCode()
                        }
                        .buttonStyle(RenewalButtonStyle(kind: .secondary))
                        .disabled(!canShareAppliedLink)
                    }

                    if let pairingError {
                        validationLabel(pairingError)
                    }
                }
            }

            SettingsSectionCard(title: "安全", systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 8) {
                    settingRow(title: "控制密码") {
                        passwordField(
                            text: $setupViewModel.lanControlPassword,
                            placeholder: passwordPlaceholder,
                            field: .password
                        )
                        .frame(maxWidth: 280)
                    }

                    settingRow(title: "确认密码") {
                        passwordField(
                            text: $setupViewModel.lanControlPasswordConfirmation,
                            placeholder: passwordPlaceholder,
                            field: .passwordConfirmation
                        )
                        .frame(maxWidth: 280)
                    }

                    settingRow(title: "") {
                        Toggle("显示密码", isOn: $showsPassword)
                            .toggleStyle(.checkbox)
                            .font(TypeTokens.caption)
                            .foregroundStyle(ColorTokens.Text.secondary)
                    }

                    if let message = setupViewModel.lanControlValidationMessage {
                        validationLabel(message)
                    }
                }
            }
        }
        .sheet(item: $pairingSheet) { sheet in
            LANControlPairingCodeView(url: sheet.url)
        }
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .frame(width: 110, alignment: .leading)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func passwordField(
        text: Binding<String>,
        placeholder: String,
        field: FocusedField
    ) -> some View {
        if showsPassword {
            TextField(placeholder, text: text)
                .textFieldStyle(
                    LANControlFieldStyle(isFocused: focusedField == field)
                )
                .focused($focusedField, equals: field)
        } else {
            SecureField(placeholder, text: text)
                .textFieldStyle(
                    LANControlFieldStyle(isFocused: focusedField == field)
                )
                .focused($focusedField, equals: field)
        }
    }

    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(TypeTokens.caption)
            .foregroundStyle(ColorTokens.Semantic.critical)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var passwordPlaceholder: String {
        setupViewModel.lanControlPasswordIsSet
            ? "已设置，留空则不修改"
            : "至少 6 个字符"
    }

    private var draftURLText: String {
        setupViewModel.lanControlDraftURL?.absoluteString
            ?? "主机或端口无效"
    }

    private var canShareAppliedLink: Bool {
        server.status.isRunning
            && !setupViewModel.hasUnsavedLANControlChanges
    }

    private var serviceTone: StatusTone {
        switch server.status {
        case .disabled:
            .neutral
        case .starting:
            .warning
        case .running:
            .good
        case .failed:
            .critical
        }
    }

    private func copyAppliedLink() {
        guard let value = server.status.accessURL?.absoluteString else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedLink = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedLink = false
        }
    }

    private func showPairingCode() {
        do {
            pairingSheet = PairingSheet(url: try issuePairingURL())
            pairingError = nil
        } catch {
            pairingError = error.localizedDescription
        }
    }
}

private struct LANControlFieldStyle: TextFieldStyle {
    let isFocused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(TypeTokens.body)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(
                    cornerRadius: SpacingTokens.Radius.control,
                    style: .continuous
                )
                .fill(ColorTokens.BG.surface)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SpacingTokens.Radius.control,
                    style: .continuous
                )
                .strokeBorder(
                    isFocused
                        ? ColorTokens.Accent.renew
                        : ColorTokens.Border.strong,
                    lineWidth: isFocused ? 1.5 : 1
                )
            )
            .overlay(focusHalo)
    }

    @ViewBuilder
    private var focusHalo: some View {
        if isFocused {
            RoundedRectangle(
                cornerRadius: SpacingTokens.Radius.control + 3,
                style: .continuous
            )
            .stroke(ColorTokens.Accent.renew.opacity(0.16), lineWidth: 3)
            .padding(-3)
            .allowsHitTesting(false)
        }
    }
}

private struct LANControlPairingCodeView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: SpacingTokens.md) {
            Text("扫描二维码进入控制页")
                .font(TypeTokens.pageTitle)
                .foregroundStyle(ColorTokens.Text.primary)

            if let image = Self.qrImage(for: url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("局域网控制一次性二维码")
            }

            Text("二维码仅可使用一次，并将在 2 分钟后失效。")
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)

            Text(url.absoluteString)
                .font(TypeTokens.mono)
                .foregroundStyle(ColorTokens.Text.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button("关闭") {
                dismiss()
            }
            .buttonStyle(RenewalButtonStyle(kind: .secondary))
            .keyboardShortcut(.cancelAction)
        }
        .padding(SpacingTokens.xl)
        .frame(width: 360)
        .background(ColorTokens.BG.canvas)
    }

    private static func qrImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ),
              let cgImage = CIContext().createCGImage(
                  output,
                  from: output.extent
              ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
