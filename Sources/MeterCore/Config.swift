import Foundation

/// `~/.config/claude-meter/config.json`. Written with defaults on first run.
public struct MeterConfig: Codable, Equatable, Sendable {
    public var schedule: WorkSchedule
    public var pollSeconds: Double
    /// "compact" (default, two stacked rows), "medium" or "full".
    public var barStyle: String?

    public static let `default` = MeterConfig(schedule: .default, pollSeconds: 120, barStyle: "compact")

    public static var url: URL { Paths.configDir.appendingPathComponent("config.json") }

    public static func load() -> MeterConfig {
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(MeterConfig.self, from: data) {
            return cfg
        }
        // Only when missing: a file that fails to parse is the user's mid-edit, not ours to replace.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(MeterConfig.default).write(to: url)
        }
        return .default
    }
}

/// One reading, as kept in the history.
public struct Sample: Codable, Equatable, Sendable {
    public var at: Date
    public var fiveHour: Double?
    public var week: Double?
    /// These tell one window from the next. Readings saved before they were recorded
    /// don't have them, and are split into windows where usage drops instead.
    public var fiveHourResetsAt: Date?
    public var weekResetsAt: Date?

    public init(at: Date, fiveHour: Double?, week: Double?, fiveHourResetsAt: Date? = nil, weekResetsAt: Date? = nil) {
        self.at = at; self.fiveHour = fiveHour; self.week = week
        self.fiveHourResetsAt = fiveHourResetsAt; self.weekResetsAt = weekResetsAt
    }

    public init(_ s: UsageSnapshot) {
        self.init(at: s.fetchedAt, fiveHour: s.fiveHour?.utilization, week: s.week?.utilization,
                  fiveHourResetsAt: s.fiveHour?.resetsAt, weekResetsAt: s.week?.resetsAt)
    }

    public func used(_ kind: LimitKind) -> Double? { kind == .fiveHour ? fiveHour : week }
    public func resetsAt(_ kind: LimitKind) -> Date? { kind == .fiveHour ? fiveHourResetsAt : weekResetsAt }
}

/// `history.jsonl`, one reading per line, so each poll appends a line rather than
/// rewriting weeks of readings.
public enum History {
    /// Enough to compare this week with the four before it.
    public static let retention: TimeInterval = 42 * 86400

    static func url(in dir: URL) -> URL { dir.appendingPathComponent("history.jsonl") }
    /// Before October 2026 the history was one JSON array, kept for eight days.
    static func legacyURL(in dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Skips lines that don't parse, such as one cut short by a crash mid-write.
    public static func load(from dir: URL) -> [Sample] {
        let dec = decoder
        var samples = ((try? String(contentsOf: url(in: dir), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? dec.decode(Sample.self, from: Data($0.utf8)) }
        // Merged rather than only converted when there's no new file yet: an older build that's
        // still running keeps rewriting the old file until it's restarted.
        if let data = try? Data(contentsOf: legacyURL(in: dir)), let old = try? dec.decode([Sample].self, from: data) {
            let known = Set(samples.map(\.at))
            samples += old.filter { !known.contains($0.at) }
            samples.sort { $0.at < $1.at }
            if save(samples, in: dir) { try? FileManager.default.removeItem(at: legacyURL(in: dir)) }
        }
        return samples.sorted { $0.at < $1.at }
    }

    public static func append(_ s: Sample, in dir: URL) {
        guard var line = try? encoder.encode(s) else { return }
        line.append(UInt8(ascii: "\n"))
        let file = url(in: dir)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? line.write(to: file, options: .atomic)
        }
    }

    /// Replaces the whole file. Returns whether it was written.
    @discardableResult
    public static func save(_ samples: [Sample], in dir: URL) -> Bool {
        let enc = encoder
        var data = Data()
        for s in samples {
            guard let line = try? enc.encode(s) else { continue }
            data.append(line); data.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: url(in: dir), options: .atomic)) != nil
    }

    public static func pruned(_ samples: [Sample], now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-retention)
        return samples.filter { $0.at >= cutoff }
    }
}

/// The last successful reading, so a restart (e.g. during a rate limit) shows data straight away.
public enum LastSnapshot {
    static func url(in dir: URL) -> URL { dir.appendingPathComponent("last.json") }

    /// The saved reading, minus any window that has reset since (its usage is unknown).
    public static func load(from dir: URL, now: Date = Date()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url(in: dir)),
              var s = try? History.decoder.decode(UsageSnapshot.self, from: data) else { return nil }
        if let f = s.fiveHour, f.resetsAt <= now { s.fiveHour = nil }
        if let w = s.week, w.resetsAt <= now { s.week = nil }
        return s.fiveHour == nil && s.week == nil ? nil : s
    }

    public static func save(_ s: UsageSnapshot, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? History.encoder.encode(s).write(to: url(in: dir), options: .atomic)
    }
}

/// How the last request went. Kept in `status.json` so a restart, or each run of the
/// `claude-meter` command, still honours a rate-limit backoff.
public struct FetchStatus: Codable, Equatable, Sendable {
    public var error: UsageError?
    public var lastAttempt: Date?
    public var backoffUntil: Date?

    public init(error: UsageError? = nil, lastAttempt: Date? = nil, backoffUntil: Date? = nil) {
        self.error = error; self.lastAttempt = lastAttempt; self.backoffUntil = backoffUntil
    }

    static func url(in dir: URL) -> URL { dir.appendingPathComponent("status.json") }

    public static func load(from dir: URL) -> FetchStatus {
        guard let data = try? Data(contentsOf: url(in: dir)) else { return FetchStatus() }
        return (try? History.decoder.decode(FetchStatus.self, from: data)) ?? FetchStatus()
    }

    public func save(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? History.encoder.encode(self).write(to: FetchStatus.url(in: dir), options: .atomic)
    }
}
