import Foundation

/// Where files live. macOS keeps its usual places; Linux follows the XDG base directories.
public enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func directory(fromEnvironment key: String) -> URL? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return URL(fileURLWithPath: v, isDirectory: true)
    }

    /// `~/.config/claude-meter`, or under `$XDG_CONFIG_HOME` on Linux.
    public static var configDir: URL {
        #if os(macOS)
        return home.appendingPathComponent(".config/claude-meter")
        #else
        return (directory(fromEnvironment: "XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config"))
            .appendingPathComponent("claude-meter")
        #endif
    }

    /// History, the last reading and fetch status. `CLAUDE_METER_DATA_DIR` overrides it,
    /// so the command can be tried against other data without touching the real history.
    public static var dataDir: URL {
        if let dir = directory(fromEnvironment: "CLAUDE_METER_DATA_DIR") { return dir }
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/ClaudeMeter")
        #else
        return (directory(fromEnvironment: "XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share"))
            .appendingPathComponent("claude-meter")
        #endif
    }

    /// Claude Code's own directory; on Linux its login is in `.credentials.json` here.
    public static var claudeDir: URL {
        directory(fromEnvironment: "CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude")
    }
}
