import Foundation

/// The meter's state and the rules for refreshing it. The macOS app and the `claude-meter`
/// command both go through this, so they poll, back off and keep history the same way.
public struct Meter {
    public var config: MeterConfig
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var history: [Sample]
    public private(set) var status: FetchStatus
    public private(set) var trends: Trends
    /// Where state is saved; nil keeps it in memory only (previews, demo data, tests).
    public let dataDir: URL?

    public static let defaultBackoff: TimeInterval = 5 * 60

    public init(config: MeterConfig, snapshot: UsageSnapshot?, history: [Sample],
                status: FetchStatus = FetchStatus(), dataDir: URL? = nil) {
        self.config = config; self.snapshot = snapshot; self.history = history
        self.status = status; self.dataDir = dataDir
        trends = Trends(history)
    }

    /// Everything saved in `dir`, minus readings older than `History.retention`.
    public static func load(config: MeterConfig = .load(), from dir: URL = Paths.dataDir, now: Date = Date()) -> Meter {
        let all = History.load(from: dir)
        let kept = History.pruned(all, now: now)
        if kept.count < all.count { History.save(kept, in: dir) }
        return Meter(config: config, snapshot: LastSnapshot.load(from: dir, now: now), history: kept,
                     status: FetchStatus.load(from: dir), dataDir: dir)
    }

    /// Not during a 429 backoff, nor within `minInterval` of the last attempt.
    public func canFetch(now: Date, minInterval: TimeInterval = 0) -> Bool {
        if let until = status.backoffUntil, now < until { return false }
        if let last = status.lastAttempt, now.timeIntervalSince(last) < minInterval { return false }
        return true
    }

    public mutating func record(_ result: Result<UsageSnapshot, UsageError>, at now: Date) {
        switch result {
        case .success(let s): record(s)
        case .failure(let e): record(e, at: now)
        }
    }

    public mutating func record(_ s: UsageSnapshot) {
        snapshot = s
        status = FetchStatus(lastAttempt: s.fetchedAt)
        let sample = Sample(s)
        history.append(sample)
        // Prune about once a day rather than rewriting the file on every poll.
        if let first = history.first, first.at < s.fetchedAt.addingTimeInterval(-History.retention - 86400) {
            history = History.pruned(history, now: s.fetchedAt)
            if let dir = dataDir { History.save(history, in: dir) }
        } else if let dir = dataDir {
            History.append(sample, in: dir)
        }
        trends = Trends(history)
        if let dir = dataDir { LastSnapshot.save(s, in: dir); status.save(in: dir) }
    }

    public mutating func record(_ error: UsageError, at now: Date) {
        var backoff: Date?
        if case .rateLimited(let retry) = error {
            backoff = now.addingTimeInterval(max(60, retry ?? Self.defaultBackoff))
        }
        status = FetchStatus(error: error, lastAttempt: now, backoffUntil: backoff)
        if let dir = dataDir { status.save(in: dir) }
    }

    public func forecast(_ kind: LimitKind, now: Date, calendar: Calendar = .current) -> Forecast? {
        guard let w = snapshot?.window(kind) else { return nil }
        return Forecast.make(utilization: w.utilization, resetsAt: w.resetsAt, windowLength: kind.length,
                             now: now, schedule: config.schedule, calendar: calendar)
    }
}

extension UsageClient {
    /// `fetch()`, with every failure as a `UsageError`.
    public func result() async -> Result<UsageSnapshot, UsageError> {
        do { return .success(try await fetch()) }
        catch let e as UsageError { return .failure(e) }
        catch { return .failure(.network(error.localizedDescription)) }
    }
}
