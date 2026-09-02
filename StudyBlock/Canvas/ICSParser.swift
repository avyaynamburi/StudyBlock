import Foundation

/// A date as iCalendar actually expresses it, which is two different things
/// wearing one property name.
///
/// Keeping them as separate cases rather than a `Date` plus an `isAllDay`
/// flag is deliberate: an all-day date is *not* an instant, and the two bugs
/// that follow from pretending otherwise (a day-long shift westward, and
/// disappearing on the morning it matters) both start with code that was
/// able to reach for a `Date`. Here there is nothing to reach for.
enum ICSDate: Equatable {
    /// A precise instant. Canvas writes these with a trailing `Z`.
    case instant(Date)
    /// A bare calendar date — `DTSTART;VALUE=DATE:20991215`. It carries no
    /// time and belongs to no timezone: "Dec 15" is Dec 15 wherever the
    /// reader is standing.
    case day(year: Int, month: Int, day: Int)
}

/// One `VEVENT`, with only the properties this app reads.
struct ICSEvent: Equatable {
    var uid: String?
    var summary: String
    var url: String?
    var start: ICSDate?
}

/// A deliberately small RFC 5545 reader: enough of the grammar to read a
/// Canvas calendar feed correctly, and no more.
///
/// Hand-rolling a parser for this format is normally the wrong call — line
/// folding, parameter lists and escaping are all easy to get subtly wrong.
/// It's done here because the app is built by `swiftc` over globbed sources
/// with no package manager, so a dependency would mean reshaping the build
/// for one file. The scope is held down to the four properties above, and
/// `Tests/canvas-sample.ics` pins the awkward cases.
enum ICSParser {
    /// Every `VEVENT` in the feed. Malformed events are skipped rather than
    /// throwing: one bad line in a 300-event feed shouldn't cost the user
    /// every other assignment.
    static func events(from data: Data) -> [ICSEvent] {
        // Canvas serves UTF-8. Fall back to Latin-1, which cannot fail, so a
        // stray invalid byte doesn't discard the whole feed.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return events(fromText: text)
    }

    static func events(fromText text: String) -> [ICSEvent] {
        var events: [ICSEvent] = []
        var current: ICSEvent?

        for line in unfold(text) {
            guard let (name, parameters, value) = property(from: line) else { continue }
            switch name {
            case "BEGIN" where value == "VEVENT":
                current = ICSEvent(summary: "")
            case "END" where value == "VEVENT":
                if let event = current { events.append(event) }
                current = nil
            case "UID":
                current?.uid = unescape(value)
            case "SUMMARY":
                current?.summary = unescape(value)
            case "URL":
                current?.url = unescape(value)
            case "DTSTART":
                current?.start = date(value: value, parameters: parameters)
            default:
                continue
            }
        }
        return events
    }

    // MARK: - Line handling

    /// Undoes RFC 5545 line folding: a line beginning with a space or a tab
    /// is a continuation of the one before it, with that first character
    /// dropped. Long Canvas assignment titles are folded routinely, so
    /// skipping this step silently truncates them.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        // Split on any newline, via `isNewline`, rather than on the character
        // "\n". Swift counts CRLF as a *single* grapheme cluster, so
        // `split(separator: "\n")` does not match it at all — and real Canvas
        // feeds are CRLF throughout, so that spelling silently returns the
        // entire feed as one line and finds no events whatsoever.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t" {
                guard !lines.isEmpty else { continue }
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    /// Splits `NAME;PARAM=VALUE:content` into its three parts.
    ///
    /// The name/parameter section is scanned by hand rather than split on the
    /// first colon, because a colon is perfectly legal inside a quoted
    /// parameter value — and always legal in the content, which is where
    /// every `URL:https://…` lives.
    static func property(from line: String) -> (name: String, parameters: [String: String], value: String)? {
        var inQuotes = false
        var colonIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ":" && !inQuotes {
                colonIndex = index
                break
            }
            index = line.index(after: index)
        }
        guard let colonIndex else { return nil }

        let head = String(line[line.startIndex..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])
        var parts = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        let name = parts.removeFirst().uppercased()
        var parameters: [String: String] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex..<equals]).uppercased()
            var raw = String(part[part.index(after: equals)...])
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            parameters[key] = raw.uppercased()
        }
        return (name, parameters, value)
    }

    /// Reverses the text escaping RFC 5545 applies to property values. A
    /// Canvas title containing a comma arrives as `Essay 1\, revised`.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var output = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n", "N": output.append("\n")
                case "\\": output.append("\\")
                case ",": output.append(",")
                case ";": output.append(";")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                output.append(character)
            }
        }
        // A value ending in a lone backslash: keep it rather than drop it.
        if escaped { output.append("\\") }
        return output
    }

    // MARK: - Dates

    /// Reads a `DATE-TIME` (`20991201T235900Z`) or, when the property says
    /// `VALUE=DATE`, a bare `DATE` (`20991215`).
    ///
    /// The `VALUE=DATE` parameter is the only thing that distinguishes the
    /// all-day case, so it is checked first and its result is never widened
    /// into an instant.
    static func date(value: String, parameters: [String: String]) -> ICSDate? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if parameters["VALUE"] == "DATE" || (trimmed.count == 8 && !trimmed.contains("T")) {
            guard let components = calendarDate(trimmed) else { return nil }
            return .day(year: components.0, month: components.1, day: components.2)
        }
        guard let instant = instant(from: trimmed, timeZoneID: parameters["TZID"]) else { return nil }
        return .instant(instant)
    }

    private static func calendarDate(_ text: String) -> (Int, Int, Int)? {
        guard text.count == 8, let number = Int(text) else { return nil }
        let year = number / 10000
        let month = (number / 100) % 100
        let day = number % 100
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }

    /// `yyyyMMdd'T'HHmmss` with an optional trailing `Z`.
    ///
    /// No zone marker and no `TZID` means a "floating" local time in the
    /// spec's terms. Canvas always sends `Z`, but a floating value is read as
    /// local rather than silently assumed to be UTC, because guessing UTC for
    /// a local time moves the deadline by the size of the offset.
    private static func instant(from text: String, timeZoneID: String?) -> Date? {
        var body = text
        var zone: TimeZone?
        if body.hasSuffix("Z") {
            body = String(body.dropLast())
            zone = TimeZone(identifier: "UTC")
        } else if let timeZoneID {
            zone = TimeZone(identifier: timeZoneID)
        }

        let parts = body.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count >= 6,
              let date = calendarDate(String(parts[0])),
              let time = Int(parts[1].prefix(6)) else { return nil }
        let hour = time / 10000
        let minute = (time / 100) % 100
        let second = time % 100
        guard hour < 24, minute < 60, second < 62 else { return nil }

        var components = DateComponents()
        components.year = date.0
        components.month = date.1
        components.day = date.2
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .current
        return calendar.date(from: components)
    }
}
