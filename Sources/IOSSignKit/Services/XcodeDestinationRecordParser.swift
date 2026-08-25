import Foundation

enum XcodeDestinationRecordIdentifier: Equatable, Sendable {
    case absent
    case value(String)
    case malformed
}

enum XcodeDestinationRecordParser {
    static func isRecord(_ line: String, requiresPlatform: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              trimmed.hasSuffix("}") else {
            return false
        }
        if requiresPlatform,
           trimmed.range(
               of: #"(?:^|[,{])\s*platform\s*:"#,
               options: .regularExpression
           ) == nil {
            return false
        }
        return identifier(in: trimmed) != .absent
    }

    static func identifier(in line: String) -> XcodeDestinationRecordIdentifier {
        let pattern = #"(?:^|[,{])\s*id\s*:\s*([^,}]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return .malformed
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = expression.matches(in: line, range: range)
        guard !matches.isEmpty else {
            return .absent
        }
        guard matches.count == 1,
              matches[0].numberOfRanges > 1,
              let valueRange = Range(matches[0].range(at: 1), in: line) else {
            return .malformed
        }
        let value = line[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .malformed : .value(value)
    }
}
