import Foundation

/// `~/.config/claude-meter/config.json`. Written with defaults on first run.
public struct MeterConfig: Codable, Equatable, Sendable {
    public var schedule: WorkSchedule
    public var pollSeconds: Double
    /// "auto" (default) picks the widest style that fits; or "full", "medium", "compact".
    public var barStyle: String?

    public static let `default` = MeterConfig(schedule: .default, pollSeconds: 120, barStyle: "auto")

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-meter/config.json")
    }

    public static func load() -> MeterConfig {
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(MeterConfig.self, from: data) {
            return cfg
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(MeterConfig.default).write(to: url)
        return .default
    }
}

/// Utilization samples kept for the popover's charts.
public struct Sample: Codable, Equatable, Sendable {
    public var at: Date
    public var fiveHour: Double?
    public var week: Double?

    public init(at: Date, fiveHour: Double?, week: Double?) {
        self.at = at; self.fiveHour = fiveHour; self.week = week
    }
}

public struct History: Sendable {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeMeter/history.json")
    }

    public static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Sample].self, from: data)) ?? []
    }

    public static func save(_ samples: [Sample]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(samples).write(to: url, options: .atomic)
    }

    /// Appends a sample and drops anything older than eight days.
    public static func appending(_ s: Sample, to samples: [Sample]) -> [Sample] {
        let cutoff = s.at.addingTimeInterval(-8 * 86400)
        return (samples + [s]).filter { $0.at >= cutoff }
    }
}
