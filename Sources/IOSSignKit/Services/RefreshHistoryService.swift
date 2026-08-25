import Foundation

struct RefreshHistoryService: Sendable {
    private static let maximumHistoryLogBytes = 512 * 1_024
    private let logStore: LogStore
    private let parser = DeployLogParser()
    private let failureAnalyzer = DeployFailureAnalyzer()

    init(logStore: LogStore = LogStore()) {
        self.logStore = logStore
    }

    func loadRecentEntries(limit: Int = 20) -> [RefreshHistoryEntry] {
        loadRecentEntries(offset: 0, limit: limit)
    }

    func loadRecentEntries(offset: Int, limit: Int) -> [RefreshHistoryEntry] {
        let urls = (try? logStore.listLogFiles()) ?? []
        return Array(
            urls
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .dropFirst(offset)
            .prefix(limit)
            .map(makeEntry(from:))
        )
    }

    func loadRecentEntriesAsync(offset: Int, limit: Int) async -> [RefreshHistoryEntry] {
        guard !Task.isCancelled else {
            return []
        }
        let entries = loadRecentEntries(offset: offset, limit: limit)
        return Task.isCancelled ? [] : entries
    }

    private func makeEntry(from url: URL) -> RefreshHistoryEntry {
        let content = boundedLogContents(at: url)
        let parsed = parser.parse(content)
        let exitStatus = parsed.exitStatus
        let processGroupWasUnresolved =
            parsed.processGroupTerminationWasConfirmed == false
        let outcome: RefreshHistoryOutcome
        if processGroupWasUnresolved {
            outcome = .interrupted
        } else if parsed.isCancelled {
            outcome = .cancelled
        } else if exitStatus == 0 {
            outcome = .success
        } else if exitStatus != nil {
            outcome = .failure
        } else {
            outcome = .unknown
        }
        let failureAnalysis = exitStatus == 0
                || parsed.isCancelled
                || processGroupWasUnresolved
            ? nil
            : failureAnalyzer.analyze(parsed)

        let summary = summaryText(from: parsed, failureAnalysis: failureAnalysis)
        let detailSummary = detailText(from: parsed, failureAnalysis: failureAnalysis)
        let excerpt = excerptText(from: parsed)
        return RefreshHistoryEntry(
            id: url.path,
            startedAt: startedAt(from: url.lastPathComponent),
            outcome: outcome,
            trigger: parsed.trigger,
            failureReason: failureAnalysis?.reason,
            summary: summary,
            detailSummary: detailSummary,
            logExcerpt: excerpt,
            logPath: url.path,
            rawFilename: url.lastPathComponent
        )
    }

    private func boundedLogContents(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard fileSize > UInt64(Self.maximumHistoryLogBytes) else {
            let data = (try? handle.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        if let standardErrorOffset = sectionMarkerOffset(
            in: handle,
            fileSize: fileSize,
            marker: Data("\n[stderr]\n".utf8)
        ) {
            let headLimit = Self.maximumHistoryLogBytes / 4
            let outputTailLimit = Self.maximumHistoryLogBytes / 4
            let errorHeadLimit = Self.maximumHistoryLogBytes / 4
            let errorTailLimit = Self.maximumHistoryLogBytes
                - headLimit
                - outputTailLimit
                - errorHeadLimit
            let head = trimmingTrailingPartialLine(read(
                from: handle,
                offset: 0,
                count: min(headLimit, Int(standardErrorOffset))
            ))
            let headEnd = UInt64(head.count)
            let requestedOutputTailOffset =
                standardErrorOffset > UInt64(outputTailLimit)
                    ? standardErrorOffset - UInt64(outputTailLimit)
                    : 0
            let outputTailOffset = max(requestedOutputTailOffset, headEnd)
            let rawOutputTail = outputTailOffset < standardErrorOffset
                ? read(
                    from: handle,
                    offset: outputTailOffset,
                    count: min(
                        outputTailLimit,
                        Int(standardErrorOffset - outputTailOffset)
                    )
                )
                : Data()
            let outputTail = outputTailOffset > headEnd
                ? trimmingLeadingPartialLine(rawOutputTail)
                : rawOutputTail
            let rawErrorHead = read(
                from: handle,
                offset: standardErrorOffset,
                count: errorHeadLimit
            )
            let errorHeadEnd = standardErrorOffset + UInt64(rawErrorHead.count)
            // Keep a bounded prefix even when stderr begins with one very long
            // diagnostic line. Dropping the partial line would erase the only
            // actionable error from history.
            let errorHead = rawErrorHead
            let requestedTailOffset = fileSize > UInt64(errorTailLimit)
                ? fileSize - UInt64(errorTailLimit)
                : 0
            let tailOffset = max(requestedTailOffset, errorHeadEnd)
            let rawTail = tailOffset < fileSize
                ? read(
                    from: handle,
                    offset: tailOffset,
                    count: errorTailLimit
                )
                : Data()
            let tail = tailOffset > errorHeadEnd
                ? trimmingLeadingPartialLine(rawTail)
                : rawTail
            let omittedStandardOutput = max(
                Int64(standardErrorOffset)
                    - Int64(head.count)
                    - Int64(outputTail.count),
                0
            )
            let omittedStandardError = max(
                Int64(fileSize - standardErrorOffset)
                    - Int64(errorHead.count)
                    - Int64(tail.count),
                0
            )
            return String(decoding: head, as: UTF8.self)
                + omissionLine(
                    section: "标准输出",
                    byteCount: omittedStandardOutput
                )
                + String(decoding: outputTail, as: UTF8.self)
                + String(decoding: errorHead, as: UTF8.self)
                + omissionLine(
                    section: "标准错误",
                    byteCount: omittedStandardError
                )
                + String(decoding: tail, as: UTF8.self)
        }

        let halfLimit = Self.maximumHistoryLogBytes / 2
        let head = trimmingTrailingPartialLine(
            read(from: handle, offset: 0, count: halfLimit)
        )
        let tail = trimmingLeadingPartialLine(read(
            from: handle,
            offset: fileSize - UInt64(halfLimit),
            count: halfLimit
        ))
        let omittedBytes = fileSize - UInt64(head.count + tail.count)
        return String(decoding: head, as: UTF8.self)
            + "\n| … 历史日志中间已省略 \(omittedBytes) 字节 …\n"
            + String(decoding: tail, as: UTF8.self)
    }

    private func sectionMarkerOffset(
        in handle: FileHandle,
        fileSize: UInt64,
        marker: Data
    ) -> UInt64? {
        let chunkSize = 64 * 1_024
        var offset: UInt64 = 0
        var overlap = Data()

        while offset < fileSize {
            let chunk = read(
                from: handle,
                offset: offset,
                count: min(chunkSize, Int(fileSize - offset))
            )
            guard !chunk.isEmpty else {
                return nil
            }
            let combined = overlap + chunk
            if let range = combined.range(of: marker) {
                let combinedStart = offset - UInt64(overlap.count)
                let relativeMarkerOffset = combined.distance(
                    from: combined.startIndex,
                    to: range.lowerBound
                )
                return combinedStart + UInt64(relativeMarkerOffset) + 1
            }
            let overlapCount = min(max(marker.count - 1, 0), combined.count)
            overlap = Data(combined.suffix(overlapCount))
            offset += UInt64(chunk.count)
        }
        return nil
    }

    private func read(
        from handle: FileHandle,
        offset: UInt64,
        count: Int
    ) -> Data {
        guard count > 0 else {
            return Data()
        }
        try? handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: count - result.count),
                      !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private func trimmingTrailingPartialLine(_ data: Data) -> Data {
        guard let newlineIndex = data.lastIndex(of: 0x0a) else {
            return Data()
        }
        return Data(data.prefix(through: newlineIndex))
    }

    private func trimmingLeadingPartialLine(_ data: Data) -> Data {
        guard let newlineIndex = data.firstIndex(of: 0x0a) else {
            return Data()
        }
        return Data(data.suffix(from: data.index(after: newlineIndex)))
    }

    private func omissionLine(section: String, byteCount: Int64) -> String {
        guard byteCount > 0 else {
            return ""
        }
        return "\n| … \(section)已省略 \(byteCount) 字节 …\n"
    }

    private func startedAt(from filename: String) -> Date? {
        DeployLogFilename.date(from: filename)
    }

    private func summaryText(
        from log: ParsedDeployLog,
        failureAnalysis: DeployFailureAnalysis?
    ) -> String {
        if log.processGroupTerminationWasConfirmed == false {
            return "续签进程树未确认结束"
        }

        if log.exitStatus == 0 {
            return "续签成功"
        }

        if log.isCancelled {
            return "已取消"
        }

        return failureAnalysis?.summary ?? "续签失败"
    }

    private func detailText(
        from log: ParsedDeployLog,
        failureAnalysis: DeployFailureAnalysis?
    ) -> String? {
        if log.processGroupTerminationWasConfirmed == false {
            return "续签主进程已结束，但完整进程树仍可能运行；新的续签已被阻止。"
        }

        if log.exitStatus == 0 {
            return log.meaningfulLines.last(where: {
                !$0.contains("File received from Device")
                    && !$0.hasSuffix(".log")
                    && !$0.hasPrefix("/")
            })
        }

        if log.isCancelled {
            return log.meaningfulLines.last(where: { $0.contains("已取消") })
                ?? "续签已由你手动停止。"
        }

        return rawFailureLine(
            from: log,
            fallback: failureAnalysis?.summary
        )
    }

    private func rawFailureLine(
        from log: ParsedDeployLog,
        fallback: String?
    ) -> String? {
        let lines = log.standardErrorLines + log.standardOutputLines
        if let xcodeError = lines.first(where: {
            $0.localizedCaseInsensitiveContains("xcodebuild: error:")
        }) {
            return DiagnosticText.bounded(xcodeError)
        }
        if let diagnostic = lines.first(where: { line in
            let normalized = line.lowercased()
            return normalized.contains("error:")
                || normalized.contains("failed")
                || normalized.contains("failure")
                || normalized.contains("timed out")
                || normalized.contains("timeout")
                || normalized.contains("错误")
                || normalized.contains("失败")
        }) {
            return DiagnosticText.bounded(diagnostic)
        }
        return fallback
    }

    private func excerptText(from log: ParsedDeployLog) -> String? {
        guard !log.meaningfulLines.isEmpty else {
            return nil
        }

        return log.meaningfulLines.suffix(6).joined(separator: "\n")
    }
}
