import Foundation

/// Round-trippable CSV for tasks.
///
/// The format is deliberately human- and LLM-writable: friendly column names,
/// word values instead of raw enum numbers ("high", not 3), and a split
/// `due_date` / `due_time` so "due Tuesday, no particular time" is expressible.
/// Only `title` is required — every other column may be omitted entirely or
/// left blank, which is what makes an AI-generated file with just
/// `title,category,due_date,repeat` a valid import.
///
/// Export writes every column, so export → import → export is lossless and
/// byte-stable.
enum TaskCSV {
    /// Full column set, in export order. The first ten (`authoringHeaders`)
    /// are the ones a person or a model actually fills in; the trailing ones
    /// are bookkeeping that only matters for exact round-trips.
    static let headers = [
        "title", "notes", "category", "category_color",
        "due_date", "due_time", "priority", "repeat", "repeat_weekdays", "repeat_until",
        "status", "list", "completed_at", "created_at", "id", "series_id", "manual_order",
    ]

    /// The subset a person — or a model — is ever expected to fill in. The
    /// rest is bookkeeping the app regenerates, and asking for it is what
    /// made AI-written files come back malformed, so `aiPrompt` and
    /// `template()` both ask for exactly these.
    static let authoringHeaders = Array(headers.prefix(10))

    // MARK: - Category colors

    /// Named stops matching `Theme.categoryHueSteps` (every 30°), so a CSV can
    /// say `blue` instead of `240`. Import also accepts a raw 0–359 number.
    static let colorNames: [(name: String, hue: Double)] = [
        ("red", 0), ("orange", 30), ("amber", 60), ("lime", 90),
        ("green", 120), ("spring", 150), ("cyan", 180), ("sky", 210),
        ("blue", 240), ("violet", 270), ("magenta", 300), ("pink", 330),
    ]

    static func colorName(for hue: Double) -> String {
        if let match = colorNames.first(where: { abs($0.hue - hue) < 0.5 }) { return match.name }
        return String(format: "%g", hue)
    }

    static func hue(fromColor raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if let match = colorNames.first(where: { $0.name == text }) { return match.hue }
        guard let number = Double(text), number.isFinite else { return nil }
        return number.truncatingRemainder(dividingBy: 360) < 0
            ? number.truncatingRemainder(dividingBy: 360) + 360
            : number.truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Formatters

    /// Local-calendar day and clock time, so `2026-09-02` means that date as
    /// the user sees it rather than a UTC instant.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Absolute timestamps (created/completed) keep full ISO-8601 with
    /// fractional seconds so they survive a round-trip unchanged.
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let lenientStampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseStamp(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return stampFormatter.date(from: text)
            ?? lenientStampFormatter.date(from: text)
            ?? dayFormatter.date(from: text)
    }

    /// `Date()` carries sub-millisecond precision that ISO-8601 can't express,
    /// which would make the first export→import shift a freshly generated
    /// timestamp by a few microseconds. Rounding to the format's own
    /// resolution keeps timestamps we invent exactly round-trippable.
    private static func stampPrecisionNow() -> Date {
        let now = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (now * 1000).rounded() / 1000)
    }

    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    // MARK: - Export

    static func encode(items: [TodoItem], hues: [String: Double]) -> String {
        var lines = [headers.joined(separator: ",")]
        for item in items {
            lines.append(row(for: item, hues: hues).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func row(for item: TodoItem, hues: [String: Double]) -> [String] {
        var dueDay = "", dueTime = ""
        if let due = item.dueDate {
            dueDay = dayFormatter.string(from: due)
            // Midnight is the app's "no specific time" convention, matching
            // the due-time toggle in the task editor.
            let parts = Calendar.current.dateComponents([.hour, .minute], from: due)
            if (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0 {
                dueTime = clockFormatter.string(from: due)
            }
        }
        let colorValue = item.course.flatMap { hues[$0] }.map(colorName(for:)) ?? ""
        let weekdays = item.repeatWeekdays.sorted()
            .compactMap { (1...7).contains($0) ? weekdayNames[$0 - 1] : nil }
            .joined(separator: " ")

        return [
            item.title,
            item.notes,
            item.course ?? "",
            colorValue,
            dueDay,
            dueTime,
            priorityName(item.priority),
            item.repeatRule.rawValue,
            weekdays,
            item.seriesEndDate.map(dayFormatter.string(from:)) ?? "",
            item.isCompleted ? "done" : "todo",
            item.column.rawValue,
            item.completedAt.map(stampFormatter.string(from:)) ?? "",
            stampFormatter.string(from: item.createdAt),
            item.id.uuidString,
            item.seriesID?.uuidString ?? "",
            item.manualOrder == .greatestFiniteMagnitude ? "" : String(item.manualOrder),
        ]
    }

    private static func priorityName(_ priority: TaskPriority) -> String {
        switch priority {
        case .none: return "none"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    // MARK: - Import

    struct ImportedRow {
        var item: TodoItem
        var categoryHue: Double?
        /// Whether the file actually named a list, vs. leaving it to the app's
        /// due-date-driven placement.
        var hadExplicitColumn: Bool
        /// Whether the row carried an `id`. An id means the row is already one
        /// materialised task (it came from an export), so it's merged as-is;
        /// no id plus a repeat rule means the row is a *definition* that
        /// `merge` expands into the whole series.
        var hadExplicitID: Bool
    }

    struct DecodeResult {
        var rows: [ImportedRow] = []
        var warnings: [String] = []
    }

    enum DecodeError: LocalizedError {
        case empty
        case missingTitleColumn

        var errorDescription: String? {
            switch self {
            case .empty:
                return "That file is empty."
            case .missingTitleColumn:
                return "That CSV has no \u{201C}title\u{201D} column — it needs at least a title for each task."
            }
        }
    }

    static func decode(_ text: String) throws -> DecodeResult {
        try decode(table: parse(text))
    }

    static func decode(table: [[String]]) throws -> DecodeResult {
        guard let headerRow = table.first else { throw DecodeError.empty }

        let keys = headerRow.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let titleIndex = keys.firstIndex(of: "title") else { throw DecodeError.missingTitleColumn }

        var result = DecodeResult()
        for (offset, fields) in table.dropFirst().enumerated() {
            let lineNumber = offset + 2 // 1-based, and the header occupies line 1
            func value(_ key: String) -> String {
                guard let index = keys.firstIndex(of: key), index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespaces)
            }

            // Skip blank padding rows rather than importing empty tasks —
            // spreadsheet exports are full of them.
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            let title = titleIndex < fields.count
                ? fields[titleIndex].trimmingCharacters(in: .whitespaces)
                : ""
            guard !title.isEmpty else {
                result.warnings.append("Line \(lineNumber): skipped — no title.")
                continue
            }

            var item = TodoItem(title: title)
            item.notes = value("notes")

            let category = value("category")
            item.course = category.isEmpty ? nil : category

            // Due date/time
            let dayText = value("due_date")
            if !dayText.isEmpty {
                if let day = dayFormatter.date(from: dayText) ?? parseStamp(dayText).map(startOfDay) {
                    let timeText = value("due_time")
                    if timeText.isEmpty {
                        item.dueDate = day
                    } else if let time = clockFormatter.date(from: timeText) {
                        item.dueDate = combine(day: day, time: time)
                    } else {
                        item.dueDate = day
                        result.warnings.append("Line \(lineNumber): couldn\u{2019}t read due_time \u{201C}\(timeText)\u{201D} — using the date only.")
                    }
                } else {
                    result.warnings.append("Line \(lineNumber): couldn\u{2019}t read due_date \u{201C}\(dayText)\u{201D} — left with no due date.")
                }
            }

            // Priority
            let priorityText = value("priority").lowercased()
            if !priorityText.isEmpty {
                switch priorityText {
                case "none", "0": item.priority = .none
                case "low", "1", "!": item.priority = .low
                case "medium", "med", "2", "!!": item.priority = .medium
                case "high", "3", "!!!": item.priority = .high
                default:
                    result.warnings.append("Line \(lineNumber): unknown priority \u{201C}\(priorityText)\u{201D} — using none.")
                }
            }

            // Repeat rule
            let repeatText = value("repeat").lowercased()
            if !repeatText.isEmpty, repeatText != "none", repeatText != "never" {
                if let rule = RepeatRule(rawValue: repeatText) {
                    item.repeatRule = rule
                } else {
                    result.warnings.append("Line \(lineNumber): unknown repeat \u{201C}\(repeatText)\u{201D} — not repeating.")
                }
            }

            // Weekdays: "mon wed fri", "Monday,Wednesday", or "2 4 6".
            let weekdayText = value("repeat_weekdays")
            if !weekdayText.isEmpty {
                let tokens = weekdayText.lowercased()
                    .split(whereSeparator: { " ,;/|".contains($0) })
                    .map(String.init)
                var weekdays = Set<Int>()
                for token in tokens {
                    if let number = Int(token), (1...7).contains(number) {
                        weekdays.insert(number)
                    } else if let index = weekdayNames.firstIndex(where: { token.hasPrefix($0) }) {
                        weekdays.insert(index + 1)
                    } else {
                        result.warnings.append("Line \(lineNumber): unknown weekday \u{201C}\(token)\u{201D} — ignored.")
                    }
                }
                item.repeatWeekdays = weekdays
            }

            // Completion
            let statusText = value("status").lowercased()
            let done = ["done", "completed", "complete", "yes", "true", "x", "1"].contains(statusText)
            item.isCompleted = done
            if done {
                item.completedAt = parseStamp(value("completed_at")) ?? stampPrecisionNow()
            }

            // How long a recurring series runs. Blank means "in perpetuity",
            // which the app materialises as a rolling runway of occurrences.
            let untilText = value("repeat_until")
            if !untilText.isEmpty {
                if let until = dayFormatter.date(from: untilText) ?? parseStamp(untilText) {
                    item.seriesEndDate = startOfDay(until)
                } else {
                    result.warnings.append("Line \(lineNumber): couldn\u{2019}t read repeat_until \u{201C}\(untilText)\u{201D} \u{2014} repeating with no end date.")
                }
            }
            if item.repeatRule == .none { item.seriesEndDate = nil }

            // Bookkeeping columns — regenerated when absent, which is the
            // normal case for a hand-written or AI-written file.
            item.createdAt = parseStamp(value("created_at")) ?? stampPrecisionNow()
            let explicitID = UUID(uuidString: value("id"))
            if let explicitID { item.id = explicitID }
            item.seriesID = UUID(uuidString: value("series_id"))

            let listText = value("list")
            var hadExplicitColumn = false
            if !listText.isEmpty {
                if let column = TaskColumn(rawValue: listText)
                    ?? TaskColumn.allCases.first(where: { $0.rawValue.lowercased() == listText.lowercased() }) {
                    item.column = column
                    hadExplicitColumn = true
                } else {
                    result.warnings.append("Line \(lineNumber): unknown list \u{201C}\(listText)\u{201D} — placing it automatically.")
                }
            }
            if done {
                item.column = .completed
                hadExplicitColumn = true
            }

            if let order = Double(value("manual_order")), order.isFinite {
                item.manualOrder = order
            } else {
                item.manualOrder = TodoItem.dateOrderValue(for: item.dueDate)
            }

            result.rows.append(ImportedRow(item: item,
                                            categoryHue: hue(fromColor: value("category_color")),
                                            hadExplicitColumn: hadExplicitColumn,
                                            hadExplicitID: explicitID != nil))
        }
        return result
    }

    // MARK: - Pasted text

    /// Pulls the CSV out of text pasted from a chat window, which usually
    /// isn't a clean file: there's a "Sure! Here are your tasks:" line on top,
    /// often ``` fences around it, and a "Let me know if you'd like changes!"
    /// on the bottom. Anything before the header row is dropped, and the rows
    /// stop at the first line too short to be a task — which is what a fence
    /// or a sentence of commentary looks like.
    ///
    /// Works on parsed rows rather than raw lines so a quoted field containing
    /// a line break isn't mistaken for the end of the table.
    static func table(fromPasted raw: String) -> [[String]] {
        let rows = parse(stripMarkdownTable(raw))
        guard let headerIndex = rows.firstIndex(where: { row in
            row.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "title" }
        }) else {
            return rows // No recognisable header; let decode() report the problem.
        }

        let header = rows[headerIndex]
        // A real data row carries roughly as many fields as the header. Prose
        // and fence markers carry one or two, so this cleanly ends the table.
        let minimumFields = header.count <= 2 ? header.count : max(2, header.count / 2)

        var result = [header]
        for row in rows[(headerIndex + 1)...] {
            let isBlank = row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if isBlank { continue }
            if row.count < minimumFields { break }
            result.append(row)
        }
        return result
    }

    /// Models asked for a CSV often hand back a markdown table instead. Rather
    /// than reject that, rewrite pipe-delimited rows into comma-delimited ones
    /// and drop the `|---|---|` separator, so the paste just works.
    /// Text that isn't a markdown table is returned untouched.
    private static func stripMarkdownTable(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let tableLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
        }
        // Only treat it as a markdown table if that's really what dominates —
        // a stray "|" in one line of a normal CSV shouldn't trigger this.
        guard tableLines.count >= 2 else { return raw }

        var converted: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") else {
                converted.append(line)
                continue
            }
            var body = trimmed
            body.removeFirst()
            if body.hasSuffix("|") { body.removeLast() }
            let cells = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // The |:---|---:| alignment row carries no data.
            if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ":-".contains($0) } }) { continue }
            converted.append(cells.map(escape).joined(separator: ","))
        }
        return converted.joined(separator: "\n")
    }

    // MARK: - Merge

    struct MergeResult {
        var items: [TodoItem]
        var hues: [String: Double]
        var added = 0
        var updated = 0
        /// Recurring definitions that were expanded, and how many tasks each
        /// produced — surfaced after an import so a single "weekly" line
        /// turning into 100 cards is never a surprise.
        var expanded: [(title: String, count: Int)] = []
        /// Recurring definitions whose date range produced nothing (an end
        /// date on or before the start date).
        var expandedEmpty: [String] = []
    }

    /// Folds decoded rows into an existing task list. Pure so the exact
    /// behaviour the app uses is what the tests exercise.
    ///
    /// Two kinds of row arrive here. A row with an `id` is one already
    /// materialised task — it replaces the matching task if there is one,
    /// which is what makes re-importing a previous export idempotent instead
    /// of duplicating the whole board. A row with **no** id but a repeat rule
    /// is a *definition*: one line saying "discussion post, weekly, Tuesdays",
    /// which is expanded here into the whole run of real tasks, exactly as
    /// the Recurring Task sheet would have created them.
    static func merge(rows: [ImportedRow], into existing: [TodoItem],
                      hues existingHues: [String: Double], now: Date = Date(),
                      calendar: Calendar = .current) -> MergeResult {
        var result = MergeResult(items: existing, hues: existingHues)

        for row in rows {
            if let course = row.item.course, let hue = row.categoryHue {
                result.hues[course] = hue
            }

            // A bare recurring definition expands into its whole series.
            if !row.hadExplicitID, !row.item.isCompleted,
               row.item.repeatRule != .none, let start = row.item.dueDate {
                var template = row.item
                template.seriesID = template.seriesID ?? UUID()
                let created = template.materializedSeries(from: start, now: now, calendar: calendar)
                result.items.append(contentsOf: created)
                result.added += created.count
                if created.isEmpty {
                    result.expandedEmpty.append(template.title)
                } else {
                    result.expanded.append((title: template.title, count: created.count))
                }
                continue
            }

            var item = row.item
            // Placement: honour an explicit list, otherwise let the due date
            // decide — the same rule the rest of the app uses.
            if item.isCompleted {
                item.column = .completed
                item.columnIsManual = true
            } else if row.hadExplicitColumn {
                item.columnIsManual = item.column != TaskColumn.automatic(forDueDate: item.dueDate, now: now, calendar: calendar)
            } else {
                item.column = TaskColumn.automatic(forDueDate: item.dueDate, now: now, calendar: calendar)
                item.columnIsManual = false
            }

            if let index = result.items.firstIndex(where: { $0.id == item.id }) {
                result.items[index] = item
                result.updated += 1
            } else {
                result.items.append(item)
                result.added += 1
            }
        }
        return result
    }

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func combine(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        var merged = DateComponents()
        merged.year = dayParts.year
        merged.month = dayParts.month
        merged.day = dayParts.day
        merged.hour = timeParts.hour
        merged.minute = timeParts.minute
        return calendar.date(from: merged) ?? day
    }

    // MARK: - Blank template

    /// Starter file for the "fill it in, then import" workflow. Only the
    /// authoring columns are present — the bookkeeping ones are regenerated
    /// on import, and including them just invited malformed rows.
    static func template() -> String {
        let examples = [
            ["Read chapter 4", "Skim the summary first", "History", "amber",
             "2026-09-03", "", "medium", "", "", ""],
            ["Discussion post", "", "History", "amber",
             "2026-09-01", "23:59", "high", "weekly", "tue", "2026-12-11"],
            ["Office hours", "", "CSDS302", "blue",
             "2026-09-04", "14:30", "none", "weekly", "thu", ""],
            ["Buy a lab notebook", "", "", "",
             "", "", "low", "", "", ""],
        ]
        var lines = [authoringHeaders.joined(separator: ",")]
        lines.append(contentsOf: examples.map { $0.map(escape).joined(separator: ",") })
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - AI prompt

    /// Instructions to paste into a chat with an AI, followed by a
    /// plain-English list of assignments, to get back an importable CSV.
    ///
    /// Two things matter most here, both learned the hard way. It asks for
    /// **only** the ten columns a human would fill in — earlier versions
    /// listed all seventeen and told the model to leave seven of them blank,
    /// which reliably produced rows with the wrong number of fields. And it
    /// tells the model to **ask questions first** rather than inventing
    /// details it wasn't given: an end date for a recurring task, a due time,
    /// which course something belongs to, or what "next week" means.
    static let aiPrompt = """
    Help me turn my assignment list into a CSV I can import into my task app.

    STEP 1 — ask me about anything I left out.
    Do NOT guess and do NOT use placeholders. Before writing any CSV, ask me \
    about anything you'd otherwise have to invent, especially:
    - For anything recurring: what date should it stop on? (If I say it runs \
    forever, leave repeat_until blank.)
    - Vague dates: "next Friday", "end of the semester", "week 3" — ask me \
    for the actual calendar date.
    - A due time, if it matters for that task.
    - Which course or subject a task belongs to, if I didn't say.
    - Anything ambiguous about how often something repeats.
    Ask all of your questions at once, in plain language, then wait for my \
    answers. If genuinely nothing is unclear, say so and go straight to step 2.

    STEP 2 — once I've answered, reply with ONLY the CSV.
    No commentary before or after, no code fences, no markdown table.

    The first line must be exactly this header row:
    \(authoringHeaders.joined(separator: ","))

    Then one line per task, with all \(authoringHeaders.count) fields on every \
    line (write nothing between two commas for a blank value). Only `title` \
    is required. Wrap a value in "double quotes" if it contains a comma, a \
    quote, or a line break.

    Columns:
    - title — the task name (required)
    - notes — longer description, or blank
    - category — course or subject, free text (e.g. History, CSDS302)
    - category_color — one of: red, orange, amber, lime, green, spring, cyan, \
    sky, blue, violet, magenta, pink. Use the SAME color every time the same \
    category appears.
    - due_date — YYYY-MM-DD. For a recurring task this is the FIRST due date.
    - due_time — HH:mm, 24-hour (e.g. 23:59). Blank means "sometime that day".
    - priority — none, low, medium, or high
    - repeat — none, daily, weekly, or monthly. Blank means none.
    - repeat_weekdays — only when repeat is weekly: space-separated days like \
    "mon wed fri". Blank means it repeats on whatever weekday due_date falls on.
    - repeat_until — YYYY-MM-DD, the last day a recurring task runs. Blank \
    means it repeats indefinitely.

    IMPORTANT about recurring tasks: write ONE line per recurring task, not \
    one line per occurrence. My app creates the individual copies itself — up \
    to \(RepeatRule.perpetualCount) of them for a task with no end date. Never \
    write out "Discussion post week 1", "Discussion post week 2", and so on.

    Example of a valid reply:
    \(authoringHeaders.joined(separator: ","))
    Essay on the Reformation,"Thesis, outline, then draft",History,amber,2026-09-04,23:59,high,none,,
    Discussion post,,History,amber,2026-09-01,23:59,high,weekly,tue,2026-12-11
    Problem set,,CSDS302,blue,2026-09-05,,medium,weekly,fri,
    Buy a lab notebook,,,,,,low,none,,

    Note the last two rows: a task with no category and no due date is fine — \
    just leave those fields empty. A recurring task with a blank repeat_until \
    repeats indefinitely.

    My assignments are:
    """

    // MARK: - RFC 4180 plumbing

    private static func escape(_ field: String) -> String {
        let needsQuotes = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
            || field != field.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Parses CSV text into rows of fields, honouring quoted fields that
    /// contain commas, newlines, or escaped (`""`) quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.startIndex

        // Strip a UTF-8 BOM, which Excel likes to prepend.
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        iterator = source.startIndex

        func endField() {
            fields.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(fields)
            fields = []
        }

        while iterator < source.endIndex {
            let character = source[iterator]
            if inQuotes {
                if character == "\"" {
                    let next = source.index(after: iterator)
                    if next < source.endIndex, source[next] == "\"" {
                        field.append("\"")
                        iterator = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    endField()
                // Swift treats CRLF as a single Character, so all three line
                // endings are matched here rather than by peeking ahead.
                case "\r\n", "\n", "\r":
                    endRow()
                default:
                    field.append(character)
                }
            }
            iterator = source.index(after: iterator)
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }
}
