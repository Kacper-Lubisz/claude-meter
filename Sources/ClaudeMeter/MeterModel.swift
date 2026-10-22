import Foundation
import MeterCore

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var history: [Sample] = History.load()
    @Published private(set) var now = Date()
    @Published private(set) var refreshing = false

    let config = MeterConfig.load()
    private let client = UsageClient()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    var onChange: (() -> Void)?

    static let fiveHourLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86400

    var fiveHour: Forecast? { forecast(snapshot?.fiveHour, length: Self.fiveHourLength) }
    var week: Forecast? { forecast(snapshot?.week, length: Self.weekLength) }

    private func forecast(_ w: LimitWindow?, length: TimeInterval) -> Forecast? {
        guard let w else { return nil }
        return Forecast.make(utilization: w.utilization, resetsAt: w.resetsAt, windowLength: length,
                             now: now, schedule: config.schedule)
    }

    var isWorkingNow: Bool { config.schedule.isWorking(at: now) }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(60, config.pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Forecasts move with the clock even between polls.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.onChange?() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false; onChange?() }
            do {
                let s = try await client.fetch()
                snapshot = s
                error = nil
                now = s.fetchedAt
                history = History.appending(Sample(at: s.fetchedAt, fiveHour: s.fiveHour?.utilization,
                                                   week: s.week?.utilization), to: history)
                History.save(history)
            } catch let e as UsageError {
                error = e
            } catch {
                self.error = .network(error.localizedDescription)
            }
        }
    }
}
