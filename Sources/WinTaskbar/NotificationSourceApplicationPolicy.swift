import Foundation

// Captured notifications expose a display name, not a reliable bundle identifier or deep link.
enum NotificationSourceApplicationPolicy {
    struct Candidate {
        let url: URL
        let names: [String]
    }

    static func applicationURL(named name: String, candidates: [Candidate]) -> URL? {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let matches = Set(candidates.filter { candidate in
            candidate.names.contains { $0.localizedCaseInsensitiveCompare(source) == .orderedSame }
        }.map { $0.url.standardizedFileURL })
        return matches.count == 1 ? matches.first : nil
    }
}
