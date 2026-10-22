import Foundation

public struct LimitWindow: Equatable, Sendable {
    public var utilization: Double
    public var resetsAt: Date

    public init(utilization: Double, resetsAt: Date) {
        self.utilization = utilization; self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var week: LimitWindow?
    public var fetchedAt: Date
}

public enum UsageError: Error, Equatable, LocalizedError {
    case noLogin, loginExpired, http(Int), badResponse, network(String)

    public var errorDescription: String? {
        switch self {
        case .noLogin: "No Claude Code login found. Run `claude` and log in."
        case .loginExpired: "Claude Code login has expired. Open Claude Code to refresh it."
        case .http(429): "Rate limited by the usage API. Retrying soon."
        case .http(let code): "Usage API returned HTTP \(code)."
        case .badResponse: "Couldn't read the usage API response."
        case .network(let msg): "Network error: \(msg)"
        }
    }
}

/// Reads limit usage from the endpoint behind Claude Code's `/usage`,
/// authenticating with Claude Code's own OAuth login from the Keychain.
/// The token is only read, never refreshed or written, so Claude Code stays in charge of it.
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    public init() {}

    public func fetch() async throws -> UsageSnapshot {
        let token = try Self.readToken()
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw UsageError.network(error.localizedDescription) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.loginExpired }
        guard code == 200 else { throw UsageError.http(code) }
        return try Self.parse(data, fetchedAt: Date())
    }

    // MARK: - Parsing

    private struct RawWindow: Decodable { var utilization: Double?; var resets_at: String? }
    private struct RawUsage: Decodable { var five_hour: RawWindow?; var seven_day: RawWindow? }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let raw = try? JSONDecoder().decode(RawUsage.self, from: data) else { throw UsageError.badResponse }
        func window(_ w: RawWindow?) -> LimitWindow? {
            guard let w, let u = w.utilization, let s = w.resets_at, let d = parseDate(s) else { return nil }
            return LimitWindow(utilization: u, resetsAt: d)
        }
        return UsageSnapshot(fiveHour: window(raw.five_hour), week: window(raw.seven_day), fetchedAt: fetchedAt)
    }

    /// Accepts ISO 8601 with any number of fractional-second digits (the API sends microseconds).
    public static func parseDate(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - Keychain

    static func readToken(now: Date = Date()) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw UsageError.noLogin }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UsageError.noLogin }

        struct Creds: Decodable {
            struct OAuth: Decodable { var accessToken: String; var expiresAt: Double? }
            var claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Creds.self, from: data))?.claudeAiOauth else { throw UsageError.noLogin }
        if let exp = oauth.expiresAt, Date(timeIntervalSince1970: exp / 1000) < now { throw UsageError.loginExpired }
        return oauth.accessToken
    }
}
