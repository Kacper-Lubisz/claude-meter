import Foundation

/// Claude Code's OAuth login. It's only read, never refreshed or written: refreshing would
/// rotate Claude Code's refresh token and could log it out.
enum Credentials {
    static let keychainService = "Claude Code-credentials"

    /// macOS keeps the login in the Keychain; Linux in `~/.claude/.credentials.json`.
    static func accessToken(now: Date = Date()) throws -> String {
        #if os(macOS)
        if let data = keychainItem() { return try accessToken(from: data, now: now) }
        #endif
        guard let data = try? Data(contentsOf: Paths.claudeDir.appendingPathComponent(".credentials.json")) else {
            throw UsageError.noLogin
        }
        return try accessToken(from: data, now: now)
    }

    static func accessToken(from data: Data, now: Date) throws -> String {
        struct Creds: Decodable {
            struct OAuth: Decodable { var accessToken: String; var expiresAt: Double? }
            var claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Creds.self, from: data))?.claudeAiOauth else { throw UsageError.noLogin }
        if let exp = oauth.expiresAt, Date(timeIntervalSince1970: exp / 1000) < now { throw UsageError.loginExpired }
        return oauth.accessToken
    }

    #if os(macOS)
    /// Through `/usr/bin/security` rather than the Security framework: the item's access
    /// list already trusts `security`, so there's no Keychain prompt.
    private static func keychainItem() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
    #endif
}
