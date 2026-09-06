import SwiftUI

struct HistoryPanelView: View {
    @FocusState private var closeButtonFocused: Bool
    @ObservedObject var viewModel: MenuBarViewModel
    let onBackToStatus: () -> Void
    var selectedEntryID: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedFilter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case success = "成功"
        case failure = "失败"
        case cancelled = "已取消"

        var id: String { rawValue }

        func includes(_ entry: RefreshHistoryEntry) -> Bool {
            switch self {
            case .all:
                true
            case .success:
                entry.outcome == .success
            case .failure:
                entry.outcome == .failure
            case .cancelled:
                entry.outcome == .cancelled
                    || entry.outcome == .interrupted
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
                .padding(.horizontal, SpacingTokens.lg)
                .padding(.vertical, 14)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { ColorTokens.Border.subtle.frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                        if filteredEntries.isEmpty {
                            emptyState
                        } else {
                            historyGroups
                        }
                    }
                    .padding(SpacingTokens.lg)
                }
                .onAppear {
                    if let selectedEntryID { proxy.scrollTo(selectedEntryID, anchor: .top) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: SpacingTokens.md) {
            Text("历史")
                .font(TypeTokens.pageTitle)
                .foregroundStyle(ColorTokens.Text.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            HStack(spacing: SpacingTokens.xs) {
                ForEach(Filter.allCases) { filter in
                    Button(filter.rawValue) {
                        withAnimation(reduceMotion ? nil : MotionTokens.easeOut()) {
                            selectedFilter = filter
                        }
                    }
                    .buttonStyle(HistoryFilterButtonStyle(isSelected: selectedFilter == filter))
                }
            }
            Spacer(minLength: 0)
            Button("完成", action: onBackToStatus)
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
                .focused($closeButtonFocused)
                .onAppear { closeButtonFocused = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyGroups: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groupedEntries, id: \.kind) { group in
                Text(group.kind.rawValue)
                    .font(TypeTokens.eyebrow)
                    .foregroundStyle(ColorTokens.Text.tertiary)
                    .tracking(0.7)
                    .padding(.horizontal, 2)
                    .padding(.top, group.kind == groupedEntries.first?.kind ? 8 : 14)
                    .padding(.bottom, 6)

                VStack(spacing: 8) {
                    ForEach(group.entries) { entry in
                        HistoryTimelineRow(
                            entry: entry,
                            dateGroup: group.kind,
                            initiallyExpanded: entry.id == selectedEntryID
                        ) {
                            viewModel.openHistoryEntry(entry)
                        }
                        .id(entry.id)
                    }
                }
            }

            if viewModel.hasMoreHistoryEntries {
                Button(
                    viewModel.isLoadingMoreHistory ? "正在加载…" : "加载更多"
                ) {
                    viewModel.loadMoreHistory()
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
                .disabled(viewModel.isLoadingMoreHistory)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            RenewalRingView(
                diameter: 44,
                lineWidth: 3,
                tone: .needsSetup,
                fraction: 0,
                centerGlyph: .none,
                isAnimationActive: false
            )

            Text(viewModel.historyEntries.isEmpty ? "还没有续签记录" : "当前筛选没有结果")
                .font(TypeTokens.cardTitle)
                .foregroundStyle(ColorTokens.Text.secondary)

            Text(
                viewModel.historyEntries.isEmpty ? "完成一次续签后，这里会展示每次结果与日志。" : "请选择其他筛选条件，或加载更多历史记录。"
            )
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.hasMoreHistoryEntries {
                Button(
                    viewModel.isLoadingMoreHistory ? "正在加载…" : "加载更多",
                    action: viewModel.loadMoreHistory
                )
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
                .disabled(viewModel.isLoadingMoreHistory)
            }
            Button("返回状态页") {
                onBackToStatus()
            }
            .buttonStyle(RenewalButtonStyle(kind: .secondary))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(
                cornerRadius: SpacingTokens.Radius.card,
                style: .continuous
            )
            .strokeBorder(
                ColorTokens.Text.tertiary,
                style: StrokeStyle(lineWidth: 1, dash: [4, 7])
            )
        )
    }

    private var filteredEntries: [RefreshHistoryEntry] {
        viewModel.historyEntries.filter(selectedFilter.includes)
    }

    private var groupedEntries: [HistoryGroup] {
        let calendar = Calendar.current
        let now = Date()

        var groups: [HistoryDateGroup: [RefreshHistoryEntry]] = [:]
        for entry in filteredEntries {
            let kind = HistoryDateGroup.resolve(
                date: entry.startedAt,
                now: now,
                calendar: calendar
            )
            groups[kind, default: []].append(entry)
        }

        return HistoryDateGroup.allCases.compactMap { kind in
            guard let entries = groups[kind], !entries.isEmpty else { return nil }
            return HistoryGroup(kind: kind, entries: entries)
        }
    }

    private struct HistoryGroup {
        let kind: HistoryDateGroup
        let entries: [RefreshHistoryEntry]
    }
}

enum HistoryDateGroup: String, CaseIterable, Hashable, Identifiable {
    case today = "今天"
    case yesterday = "昨天"
    case thisWeek = "本周"
    case earlier = "更早"

    var id: Self { self }

    static func resolve(
        date: Date?,
        now: Date,
        calendar: Calendar
    ) -> HistoryDateGroup {
        guard let date else { return .earlier }
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }

        let dateWeek = calendar.dateComponents(
            [.weekOfYear, .yearForWeekOfYear],
            from: date
        )
        let currentWeek = calendar.dateComponents(
            [.weekOfYear, .yearForWeekOfYear],
            from: now
        )
        return dateWeek == currentWeek ? .thisWeek : .earlier
    }
}

enum HistoryTimelineTimePresentation {
    static func text(
        for date: Date?,
        group: HistoryDateGroup,
        calendar: Calendar
    ) -> String {
        guard let date else { return "—" }
        switch group {
        case .today, .yesterday:
            return formatted(
                date,
                pattern: "HH:mm",
                calendar: calendar
            )
        case .thisWeek:
            let symbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = calendar.component(.weekday, from: date)
            return symbols[max(min(weekday - 1, symbols.count - 1), 0)]
        case .earlier:
            return formatted(
                date,
                pattern: "MM-dd",
                calendar: calendar
            )
        }
    }

    private static func formatted(
        _ date: Date,
        pattern: String,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct HistoryResultRingPresentation: Equatable {
    let tone: RenewalRingView.Tone
    let glyph: RenewalRingView.CenterGlyph
    let fraction: Double

    static func make(
        outcome: RefreshHistoryOutcome
    ) -> HistoryResultRingPresentation {
        switch outcome {
        case .success:
            return HistoryResultRingPresentation(
                tone: .success,
                glyph: .none,
                fraction: 1
            )
        case .failure:
            return HistoryResultRingPresentation(
                tone: .critical,
                glyph: .exclamation,
                fraction: 1
            )
        case .cancelled, .interrupted, .unknown:
            return HistoryResultRingPresentation(
                tone: .offline,
                glyph: .verticalLine,
                fraction: 1
            )
        }
    }
}

struct HistoryTimelineRow: View {
    let entry: RefreshHistoryEntry
    let dateGroup: HistoryDateGroup
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        entry: RefreshHistoryEntry, dateGroup: HistoryDateGroup, initiallyExpanded: Bool = false,
        onOpen: @escaping () -> Void
    ) {
        self.entry = entry
        self.dateGroup = dateGroup
        self.onOpen = onOpen
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : MotionTokens.easeOut()) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: SpacingTokens.sm) {
                    RenewalRingView(
                        diameter: 26,
                        lineWidth: 2.5,
                        tone: ringPresentation.tone,
                        fraction: ringPresentation.fraction,
                        centerGlyph: ringPresentation.glyph,
                        isAnimationActive: false
                    )

                    Text(timeText)
                        .font(TypeTokens.mono)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .frame(width: 52, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rowPresentation.title)
                            .font(TypeTokens.body.weight(.medium))
                            .foregroundStyle(ColorTokens.Text.primary)
                            .lineLimit(1)

                        if let detail = rowPresentation.subtitle {
                            Text(detail)
                                .font(TypeTokens.mono)
                                .foregroundStyle(ColorTokens.Text.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    StatusPill(text: statusText, tone: statusTone)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ColorTokens.Text.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(statusText)，\(timeText)，\(rowPresentation.title)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityHint(isExpanded ? "收起日志片段" : "展开日志片段")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.logExcerpt ?? "没有可显示的日志片段。")
                        .font(TypeTokens.mono)
                        .foregroundStyle(ColorTokens.Log.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: SpacingTokens.Radius.control,
                                style: .continuous
                            )
                            .fill(ColorTokens.Log.background)
                        )

                    HStack {
                        Spacer(minLength: 0)
                        Button("打开完整日志", systemImage: "arrow.up.right") {
                            onOpen()
                        }
                        .buttonStyle(RenewalButtonStyle(kind: .text))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .interfaceSurface()
        .shadow(
            color: .black.opacity(isHovering ? 0.08 : 0),
            radius: isHovering ? 7 : 0,
            x: 0,
            y: isHovering ? 4 : 0
        )
        .offset(x: isHovering && !reduceMotion ? 3 : 0)
        .animation(reduceMotion ? nil : MotionTokens.easeOut(), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var timeText: String {
        HistoryTimelineTimePresentation.text(
            for: entry.startedAt,
            group: dateGroup,
            calendar: .current
        )
    }

    private var statusText: String {
        switch entry.outcome {
        case .success:
            "成功"
        case .failure:
            "失败"
        case .cancelled, .interrupted:
            "已取消"
        case .unknown:
            "未知"
        }
    }

    private var rowPresentation: HistoryEntryPresentation {
        HistoryEntryPresentation.make(entry: entry)
    }

    private var statusTone: StatusTone {
        switch entry.outcome {
        case .success:
            .good
        case .failure:
            .critical
        case .cancelled, .interrupted, .unknown:
            .neutral
        }
    }

    private var ringPresentation: HistoryResultRingPresentation {
        HistoryResultRingPresentation.make(outcome: entry.outcome)
    }
}

struct HistoryEntryPresentation: Equatable {
    let title: String
    let subtitle: String?

    static func make(entry: RefreshHistoryEntry) -> HistoryEntryPresentation {
        switch entry.outcome {
        case .success:
            return HistoryEntryPresentation(
                title: "续签成功 · \(successTriggerText(entry: entry))",
                subtitle: normalizedSubtitle(entry.detailSummary, excluding: entry.summary)
            )
        case .failure:
            return HistoryEntryPresentation(
                title: "续签失败 · \(failureReasonText(entry: entry))",
                subtitle: normalizedSubtitle(entry.detailSummary ?? entry.summary)
            )
        case .cancelled:
            return HistoryEntryPresentation(
                title: "已取消 · 用户停止",
                subtitle: normalizedSubtitle(entry.detailSummary, excluding: entry.summary)
            )
        case .interrupted:
            return HistoryEntryPresentation(
                title: "已取消 · 续签中断",
                subtitle: normalizedSubtitle(entry.detailSummary ?? entry.summary)
            )
        case .unknown:
            return HistoryEntryPresentation(
                title: "续签结果待确认",
                subtitle: normalizedSubtitle(entry.detailSummary ?? entry.summary)
            )
        }
    }

    private static func successTriggerText(
        entry: RefreshHistoryEntry
    ) -> String {
        switch entry.trigger {
        case .automatic:
            return "自动续期"
        case .manual:
            return "手动触发"
        case nil:
            break
        }

        let searchable = [
            entry.summary,
            entry.detailSummary,
            entry.logExcerpt
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
        if searchable.contains("自动续期")
            || searchable.contains("automatic refresh")
            || searchable.contains("automatic renewal") {
            return "自动续期"
        }
        return "手动触发"
    }

    private static func failureReasonText(
        entry: RefreshHistoryEntry
    ) -> String {
        if entry.failureReason == .devicePreparationRequired {
            return "设备准备超时"
        }

        let normalized = [
            entry.summary,
            entry.detailSummary,
            entry.logExcerpt
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
        if normalized.contains("unlock") || normalized.contains("解锁") {
            return "设备未解锁"
        }
        if normalized.contains("destination") {
            return "目标设备不可用"
        }
        if normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("超时") {
            return "操作超时"
        }
        if normalized.contains("profile")
            || normalized.contains("provision")
            || normalized.contains("signing")
            || normalized.contains("签名") {
            return "签名配置错误"
        }
        return "构建或安装失败"
    }

    private static func normalizedSubtitle(
        _ value: String?,
        excluding excludedValue: String? = nil
    ) -> String? {
        guard let firstLine = value?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !firstLine.isEmpty,
              firstLine != excludedValue else {
            return nil
        }
        return firstLine
    }
}

private struct HistoryFilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeTokens.caption.weight(.medium))
            .foregroundStyle(
                isSelected ? ColorTokens.BG.canvas : ColorTokens.Text.secondary
            )
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? ColorTokens.Text.primary : ColorTokens.BG.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : ColorTokens.Border.strong,
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
