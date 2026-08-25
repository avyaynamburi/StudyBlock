import Foundation

struct QuickAddResult: Equatable {
    var title: String
    var course: String?
    var dueDate: Date?
    var priority: TaskPriority = .none
}

/// Parses TickTick-style quick-add input:
///   "p.142 problems #math friday !!"
/// → title "p.142 problems", course "math", due next Friday, priority medium.
///
/// `#word` sets the course, a standalone !/!!/!!! sets priority, and any
/// natural-language date NSDataDetector finds ("tomorrow", "friday",
/// "jun 12") becomes the due date and is removed from the title.
enum QuickAddParser {
    static func parse(_ input: String) -> QuickAddResult {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var working = original
        var result = QuickAddResult(title: original)

        if let courseRange = working.range(of: "#[A-Za-z0-9_-]+", options: .regularExpression) {
            result.course = String(working[courseRange].dropFirst())
            working.removeSubrange(courseRange)
        }

        if let bangRange = working.range(of: "(?<=\\s|^)!{1,3}(?=\\s|$)", options: .regularExpression) {
            switch working[bangRange].count {
            case 1: result.priority = .low
            case 2: result.priority = .medium
            default: result.priority = .high
            }
            working.removeSubrange(bangRange)
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = working as NSString
            let match = detector.matches(in: working, range: NSRange(location: 0, length: ns.length))
                .first { $0.date != nil }
            if let match, let date = match.date, let range = Range(match.range, in: working) {
                result.dueDate = Calendar.current.startOfDay(for: date)
                working.removeSubrange(range)
            }
        }

        let title = working
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If stripping consumed everything ("friday" alone), keep the raw
        // input as the title rather than creating a nameless task.
        result.title = title.isEmpty ? original : title
        return result
    }
}
