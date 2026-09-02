import CryptoKit
import Foundation

/// What a Canvas feed entry is. The feed mixes both, and the distinction is
/// not cosmetic: `DTSTART` on an assignment is the moment it is *due*, and on
/// an event the moment it *starts*. Missing the first costs a late
/// submission; missing the second costs a walk to the wrong room.
enum CanvasItemKind: String, Equatable {
    case assignment
    case event

    /// The verb this kind takes, chosen by lookup so no other layer has to
    /// re-derive whether a timestamp is a deadline.
    var verb: String {
        switch self {
        case .assignment: return "due"
        case .event: return "starts"
        }
    }
}

/// One normalized entry from Canvas, independent of how it was fetched.
///
/// `dueAt` and `startsAt` are mutually exclusive by construction — an
/// assignment fills the first, an event the second — so nothing downstream
/// ever has to ask which kind of timestamp it is holding.
struct CanvasItem: Equatable {
    var sourceID: String
    var kind: CanvasItemKind
    /// The assignment name with the course stripped off.
    var title: String
    /// The `[PHYS 221]` the feed appends to the summary, if there was one.
    var course: String?
    var dueAt: ICSDate?
    var startsAt: ICSDate?
    var url: String?

    /// Whichever timestamp this kind carries.
    var when: ICSDate? { dueAt ?? startsAt }

    /// The title as it should read on a board that has no course column of
    /// its own: "PHYS 221: Problem Set 5".
    var qualifiedTitle: String {
        guard let course, !course.isEmpty else { return title }
        return "\(course): \(title)"
    }

    /// Identity plus content, hashed. Two syncs that produce the same hash
    /// for the same `sourceID` describe the same assignment, unchanged.
    ///
    /// The due date is *inside* the hash on purpose. A seen-set keyed on
    /// identity alone silently swallows a professor pushing a deadline back,
    /// which is the single most important update this feature can deliver.
    var contentHash: String {
        let payload = [
            kind.rawValue,
            title,
            course ?? "",
            CanvasItem.hashComponent(dueAt),
            CanvasItem.hashComponent(startsAt),
            url ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A date rendered for hashing only — fixed format, fixed zone, so the
    /// hash is stable across runs, machines, and locales. `Date`'s own
    /// description is none of those things.
    private static func hashComponent(_ date: ICSDate?) -> String {
        switch date {
        case nil:
            return ""
        case .instant(let instant):
            return "i\(Int(instant.timeIntervalSince1970))"
        case .day(let year, let month, let day):
            return String(format: "d%04d-%02d-%02d", year, month, day)
        }
    }
}

enum CanvasNormalizer {
    /// Canvas hangs the course code off the end of the summary. Anchored to
    /// the end of the string so an assignment legitimately titled
    /// "Lab 3 [revised] handout" keeps its middle bracket.
    private static let courseSuffix = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\s*$")

    /// Splits "Problem Set 5 [PHYS 221]" into its title and course.
    static func splitCourse(_ summary: String) -> (title: String, course: String?) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let courseSuffix,
              let match = courseSuffix.firstMatch(in: trimmed, range: range),
              let whole = Range(match.range, in: trimmed),
              let inner = Range(match.range(at: 1), in: trimmed) else {
            return (trimmed, nil)
        }
        let title = String(trimmed[trimmed.startIndex..<whole.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let course = String(trimmed[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A summary that is *only* a bracketed course has no title to keep;
        // fall back to the whole string rather than producing a nameless task.
        guard !title.isEmpty else { return (trimmed, nil) }
        return (title, course.isEmpty ? nil : course)
    }

    /// Assignments carry `/courses/<id>/assignments/<id>` URLs and
    /// `event-assignment-<n>` UIDs; calendar events carry `calendar?event_id=`
    /// and `event-calendar-<n>`. Both are checked so a feed missing one field
    /// still classifies correctly.
    static func isAssignment(url: String?, uid: String?) -> Bool {
        if let url, url.contains("/assignments/") { return true }
        if let uid, uid.lowercased().contains("assignment") { return true }
        return false
    }

    /// Turns raw events into normalized items.
    ///
    /// An event with no `DTSTART` is dropped, never defaulted to now: there
    /// is nowhere on a timeline to honestly put it.
    static func normalize(_ events: [ICSEvent]) -> [CanvasItem] {
        events.compactMap { event in
            guard let start = event.start else { return nil }
            let (title, course) = splitCourse(event.summary)
            guard !title.isEmpty else { return nil }

            let assignment = isAssignment(url: event.url, uid: event.uid)
            // Prefer the UID: it is stable across fetches, which is the whole
            // basis for recognising an assignment we have already imported.
            // The last fallback is deliberately weak — if the title or time
            // moves, identity moves with it and the item re-imports as new.
            let sourceID = event.uid
                ?? event.url
                ?? "\(title)|\(CanvasItem(sourceID: "", kind: .event, title: title, course: course, startsAt: start).contentHash)"

            return CanvasItem(
                sourceID: sourceID,
                kind: assignment ? .assignment : .event,
                title: title,
                course: course,
                dueAt: assignment ? start : nil,
                startsAt: assignment ? nil : start,
                url: event.url)
        }
    }

    /// Drops anything already in the past.
    ///
    /// An all-day entry is compared by calendar date, never by instant. Left
    /// as an instant comparison it would be dropped at midnight UTC — which
    /// is to say, it would vanish on the very morning it mattered.
    static func upcoming(_ items: [CanvasItem], now: Date = Date(),
                         calendar: Calendar = .current) -> [CanvasItem] {
        let today = calendar.startOfDay(for: now)
        return items.filter { item in
            switch item.when {
            case nil:
                return false
            case .instant(let instant):
                return instant >= now
            case .day(let year, let month, let day):
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                guard let date = calendar.date(from: components) else { return false }
                return calendar.startOfDay(for: date) >= today
            }
        }
    }

    /// The due date as this app stores it: a single `Date` in the local
    /// calendar.
    ///
    /// An all-day entry becomes local midnight, which is not a claim that it
    /// is due at 00:00 — it is how the whole app already encodes "a date with
    /// no time", the same convention the task editor's "Due time" switch
    /// reads. Building it from calendar components in the local calendar is
    /// what keeps it on the right day; converting an instant would not.
    static func localDueDate(_ date: ICSDate, calendar: Calendar = .current) -> Date? {
        switch date {
        case .instant(let instant):
            return instant
        case .day(let year, let month, let day):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
        }
    }
}
