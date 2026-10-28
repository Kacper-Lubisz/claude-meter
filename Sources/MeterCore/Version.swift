import Foundation

/// This build's version, and whether the checkout it was built from has moved on since.
public enum Version {
    /// Bump with every change, so an installed build can tell it's behind the repo.
    public static let current = "0.2.0"

    /// This file, where it was when the build was made.
    static let source = URL(fileURLWithPath: #filePath)

    /// The version in the checkout now, if it's still where this was built from.
    public static func inRepo() -> String? {
        (try? String(contentsOf: source, encoding: .utf8)).flatMap(declared)
    }

    /// The `current` declared in a copy of this file.
    static func declared(in swift: String) -> String? {
        guard let line = swift.split(separator: "\n").first(where: { $0.contains("static let current = \"") }) else { return nil }
        return line.split(separator: "\"").dropFirst().first.map(String.init)
    }

    /// Whether `a` comes after `b`: "0.10.0" comes after "0.9.1".
    public static func isLater(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// The repo's version, when it's later than this build's.
    public static func newerInRepo() -> String? {
        inRepo().flatMap { isLater($0, than: current) ? $0 : nil }
    }
}
