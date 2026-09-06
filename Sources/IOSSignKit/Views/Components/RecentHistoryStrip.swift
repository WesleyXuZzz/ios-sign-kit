import SwiftUI

struct RecentHistoryStrip: View {
    let entries: [RefreshHistoryEntry]
    let allHistoryFocus: FocusState<Bool>.Binding
    let onOpen: (String?) -> Void
    static let maximumEntries = 4

    var body: some View {
        HStack(spacing: 12) {
            Label("历史", systemImage: "clock.arrow.circlepath")
                .font(TypeTokens.caption.weight(.semibold))
                .foregroundStyle(ColorTokens.Text.secondary)
            if entries.isEmpty {
                Text("还没有续签记录")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(entries.prefix(Self.maximumEntries))) { entry in
                        let summary = HistoryEntryPresentation.make(entry: entry)
                        let ring = HistoryResultRingPresentation.make(outcome: entry.outcome)
                        Button {
                            onOpen(entry.id)
                        } label: {
                            HStack(spacing: 6) {
                                RenewalRingView(
                                    diameter: 16, lineWidth: 2, tone: ring.tone,
                                    fraction: ring.fraction, centerGlyph: ring.glyph,
                                    isAnimationActive: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        entry.startedAt.map {
                                            $0.formatted(date: .omitted, time: .shortened)
                                        } ?? "时间未知"
                                    )
                                    .font(TypeTokens.mono)
                                    .foregroundStyle(ColorTokens.Text.secondary)
                                    Text(summary.title)
                                        .font(TypeTokens.auxiliary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RenewalButtonStyle(kind: .text))
                        .help(
                            [summary.title, summary.subtitle].compactMap { $0 }.joined(
                                separator: " · ")
                        )
                        .accessibilityLabel(summary.title)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Button("全部历史", systemImage: "chevron.right") { onOpen(nil) }
                .focused(allHistoryFocus)
                .buttonStyle(RenewalButtonStyle(kind: .text))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .interfaceSurface()
    }
}
