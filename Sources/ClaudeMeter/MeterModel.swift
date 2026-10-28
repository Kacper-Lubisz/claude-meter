import Foundation
import MeterCore

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var meter: Meter
    @Published private(set) var now = Date()
    @Published private(set) var refreshing = false
    /// The repo's version, when it's later than this build's.
    @Published private(set) var newerVersion = Version.newerInRepo()

    /// The popover's tab and what each comparison is against (nil = the default). Kept here
    /// rather than in SwiftUI `@State`, whose macro plugin the Command Line Tools don't ship.
    @Published var tab: PopoverView.Tab = .now
    @Published var pickedDay: Date?
    @Published var pickedWindow: [LimitKind: Date] = [:]
    /// Whether week and day charts squeeze the time outside working hours.
    @Published var squeezeOffHours = true

    private let client = UsageClient()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    var onChange: (() -> Void)?

    init(meter: Meter = .load()) { self.meter = meter }

    var config: MeterConfig { meter.config }
    var snapshot: UsageSnapshot? { meter.snapshot }
    var error: UsageError? { meter.status.error }
    var trends: Trends { meter.trends }
    var fiveHour: Forecast? { meter.forecast(.fiveHour, now: now) }
    var week: Forecast? { meter.forecast(.week, now: now) }
    var isWorkingNow: Bool { config.schedule.isWorking(at: now) }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(60, config.pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Forecasts move with the clock even between polls.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.newerVersion = Version.newerInRepo()
                self?.onChange?()
            }
        }
    }

    func refresh() {
        guard !refreshing, meter.canFetch(now: Date()) else { return }
        Task { await load() }
    }

    /// Opening the popover refreshes, but not more than once a minute.
    func refreshIfStale() {
        guard meter.canFetch(now: Date(), minInterval: 60) else { return }
        refresh()
    }

    /// Shows fixed data instead of polling. Used by `--preview-popover`.
    func show(_ m: Meter, at time: Date) {
        meter = m; now = time
    }

    func load() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; onChange?() }
        let result = await client.result()
        if case .failure(let e) = result { log("fetch failed: \(e.localizedDescription)") }
        now = Date()
        meter.record(result, at: now)
    }
}
