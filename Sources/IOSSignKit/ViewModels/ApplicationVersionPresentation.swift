import Foundation

struct ApplicationVersionPresentation: Equatable {
    let marketingVersion: String?
    let buildVersion: String?

    static var current: ApplicationVersionPresentation {
        make(infoDictionary: Bundle.main.infoDictionary)
    }

    var sidebarText: String {
        marketingVersion.map { "版本 \($0)" } ?? "版本 —"
    }

    var detailText: String {
        switch (marketingVersion, buildVersion) {
        case let (.some(version), .some(build)):
            "版本 \(version)（构建 \(build)）"
        case let (.some(version), .none):
            "版本 \(version)"
        case let (.none, .some(build)):
            "构建 \(build)"
        case (.none, .none):
            "版本信息不可用"
        }
    }

    static func make(
        infoDictionary: [String: Any]?
    ) -> ApplicationVersionPresentation {
        ApplicationVersionPresentation(
            marketingVersion: normalizedValue(
                infoDictionary?["CFBundleShortVersionString"] as? String
            ),
            buildVersion: normalizedValue(
                infoDictionary?["CFBundleVersion"] as? String
            )
        )
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
