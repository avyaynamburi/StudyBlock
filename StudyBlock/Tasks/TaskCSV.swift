import Foundation

/// Round-trippable CSV for tasks.
///
/// The columns are the controls of the task sheets, one for one — category,
/// color, due date, due time, repeat, end date, notes — so anything
/// the app can express, a row can, and vice versa. Values are words, not enum
/// numbers ("high", not 3), and `due_date` / `due_time` are split so "due
/// Tuesday, no particular time" is expressible. Only `title` is required.
///
/// Two decisions here exist specifically to survive AI-written files, where
/// the failure mode is never a wrong value — it's a row with the wrong number
/// of fields, which silently shifts every column after the mistake:
///
/// - The whole repeat schedule is **one** `repeat` code (`2w:tue` is "every
///   other Tuesday"), not a rule column plus a weekdays column. One fewer
///   column is one fewer chance to misalign, and the code is self-describing
///   in a way `weekly` + a separate day list is not.
/// - `notes` is **last**. It's the field most likely to contain a comma the
///   model forgot to quote, and at the end of the row that costs a truncated
///   note; anywhere else it corrupts every column that follows.
///
/// Export writes every column, so export → import → export is lossless and
/// byte-stable.
enum TaskCSV {
    /// Full column set, in export order. The first nine (`authoringHeaders`)
    /// are the ones a person or a model actually fills in; the trailing ones
    /// are bookkeeping that only matters for exact round-trips.
    static let headers = [
        "title", "category", "color", "due_date", "due_time",
        "repeat", "repeat_until", "notes",
        "status", "list", "completed_at", "created_at", "id", "series_id", "manual_order",
    ]

    /// The subset a person — or a model — is ever expected to fill in. The
    /// rest is bookkeeping the app regenerates, and asking for it is what
    /// made AI-written files come back malformed, so `aiPrompt` and
    /// `template()` both ask for exactly these.
    static let authoringHeaders = Array(headers.prefix(8))

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

    /// Always a word, never a number: the closest named stop to `hue`, going
    /// the short way round the wheel. The AI prompt lists the board's existing
    /// categories with these names, and "cyan" is a far better instruction to
    /// a model than "187".
    static func nearestColorName(for hue: Double) -> String {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        let normalized = wrapped < 0 ? wrapped + 360 : wrapped
        let nearest = colorNames.min { left, right in
            func distance(_ stop: Double) -> Double {
                let raw = abs(stop - normalized)
                return min(raw, 360 - raw)
            }
            return distance(left.hue) < distance(right.hue)
        }
        return nearest?.name ?? "blue"
    }

    // MARK: - Repeat codes

    /// One decoded `repeat` cell.
    struct ParsedRepeat {
        var rule: RepeatRule = .none
        var interval = 1
        var weekdays: Set<Int> = []
    }

    /// The legend, in the order it's shown to the user and to the AI. Kept as
    /// data so the prompt, the format doc, and the parser can't drift apart.
    static let repeatLegend: [(code: String, meaning: String)] = [
        ("(blank)", "doesn\u{2019}t repeat"),
        ("d", "every day"),
        ("3d", "every 3 days"),
        ("w", "every week, on whatever day due_date falls on"),
        ("2w", "every 2 weeks"),
        ("w:mon wed fri", "every week on Mon, Wed and Fri"),
        ("2w:tue", "every other Tuesday"),
        ("m", "every month, on the same day of the month"),
        ("3m", "every 3 months"),
        ("12m", "every year"),
    ]

    /// Renders a task's schedule as a `repeat` code. Weekdays are separated by
    /// spaces rather than commas so the cell never needs quoting.
    static func repeatCode(rule: RepeatRule, interval: Int, weekdays: Set<Int>) -> String {
        guard rule != .none else { return "" }
        var code = interval > 1 ? String(interval) : ""
        code += rule.unitCode
        guard rule == .weekly, !weekdays.isEmpty else { return code }
        let days = weekdays.sorted().compactMap { (1...7).contains($0) ? weekdayNames[$0 - 1] : nil }
        return code + ":" + days.joined(separator: " ")
    }

    /// Reads a `repeat` cell. Deliberately forgiving, because this is the one
    /// column a model is most likely to write in its own words: `2w`, `every
    /// 2 weeks`, `biweekly`, `weekly on mon,wed` and `Every Other Week` all
    /// land in the same place. Returns nil only for something unrecognisable,
    /// which the caller reports as a warning rather than guessing at.
    static func parseRepeat(_ raw: String) -> ParsedRepeat? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: " ")
        guard !text.isEmpty else { return ParsedRepeat() }
        if ["none", "never", "no", "n/a", "once", "one time", "0"].contains(text) {
            return ParsedRepeat()
        }

        // A day list, however it was attached: "w:mon wed", "weekly on mon".
        var weekdays: Set<Int> = []
        for separator in [":", " on ", "@"] where text.contains(separator) {
            guard let range = text.range(of: separator) else { continue }
            weekdays = parseWeekdays(String(text[range.upperBound...])).days
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }

        // "every"/"each" is noise; "other" is the word for an interval of 2.
        var interval = 1
        for filler in ["every ", "each ", "repeats ", "repeat "] where text.hasPrefix(filler) {
            text.removeFirst(filler.count)
        }
        if text.hasPrefix("other ") {
            interval = 2
            text.removeFirst("other ".count)
        }
        let digits = text.prefix { $0.isNumber }
        if !digits.isEmpty, let count = Int(digits) {
            interval = max(1, count)
            text.removeFirst(digits.count)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // The unit, and how many of the base unit it stands for — a year is
        // simply twelve months, which is why there's no separate rule for it.
        let unit: (rule: RepeatRule, months: Int)
        switch text {
        case "d", "day", "days", "daily": unit = (.daily, 1)
        case "w", "week", "weeks", "weekly": unit = (.weekly, 1)
        case "m", "month", "months", "monthly": unit = (.monthly, 1)
        case "y", "year", "years", "yearly", "annually", "annual": unit = (.monthly, 12)
        case "biweekly", "fortnightly", "fortnight": unit = (.weekly, 2)
        case "bimonthly": unit = (.monthly, 2)
        case "weekday", "weekdays", "school day", "school days":
            // Mon–Fri, the one named day-set worth understanding.
            if weekdays.isEmpty { weekdays = [2, 3, 4, 5, 6] }
            unit = (.weekly, 1)
        default:
            return nil
        }

        return ParsedRepeat(rule: unit.rule,
                            interval: interval * unit.months,
                            weekdays: unit.rule == .weekly ? weekdays : [])
    }

    /// Reads a day list in any of the shapes a person or model writes one:
    /// "mon wed fri", "Monday, Wednesday", "2 4 6". Returns the days it
    /// understood plus the tokens it didn\u{2019}t, so the caller can warn.
    static func parseWeekdays(_ raw: String) -> (days: Set<Int>, unknown: [String]) {
        var days = Set<Int>()
        var unknown: [String] = []
        for token in raw.lowercased().split(whereSeparator: { " ,;/|".contains($0) }).map(String.init) {
            if let number = Int(token), (1...7).contains(number) {
                days.insert(number)
            } else if let index = weekdayNames.firstIndex(where: { token.hasPrefix($0) }) {
                days.insert(index + 1)
            } else {
                unknown.append(token)
            }
        }
        return (days, unknown)
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

        return [
            item.title,
            item.course ?? "",
            colorValue,
            dueDay,
            dueTime,
            repeatCode(rule: item.repeatRule, interval: item.repeatInterval,
                       weekdays: item.repeatWeekdays),
            item.seriesEndDate.map(dayFormatter.string(from:)) ?? "",
            item.notes,
            item.isCompleted ? "done" : "todo",
            item.column.rawValue,
            item.completedAt.map(stampFormatter.string(from:)) ?? "",
            stampFormatter.string(from: item.createdAt),
            item.id.uuidString,
            item.seriesID?.uuidString ?? "",
            item.manualOrder == .greatestFiniteMagnitude ? "" : String(item.manualOrder),
        ]
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
            /// First of `names` the file actually has a column for, so a CSV
            /// written against the older header (`category_color`) still
            /// reads correctly.
            func value(_ names: String...) -> String {
                for name in names {
                    guard let index = keys.firstIndex(of: name), index < fields.count else { continue }
                    let text = fields[index].trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return text }
                }
                return ""
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

            // Repeat: one coded column ("2w:tue"). A file written against the
            // older two-column shape still works — `parseRepeat` reads its
            // plain "weekly", and `repeat_weekdays` supplies the days.
            let repeatText = value("repeat", "repeats", "frequency")
            if !repeatText.isEmpty {
                if let parsed = parseRepeat(repeatText) {
                    item.repeatRule = parsed.rule
                    item.repeatInterval = parsed.interval
                    item.repeatWeekdays = parsed.weekdays
                } else {
                    result.warnings.append("Line \(lineNumber): couldn\u{2019}t read repeat \u{201C}\(repeatText)\u{201D} — not repeating.")
                }
            }

            let weekdayText = value("repeat_weekdays")
            if !weekdayText.isEmpty, item.repeatRule == .weekly, item.repeatWeekdays.isEmpty {
                let parsed = parseWeekdays(weekdayText)
                item.repeatWeekdays = parsed.days
                for token in parsed.unknown {
                    result.warnings.append("Line \(lineNumber): unknown weekday \u{201C}\(token)\u{201D} — ignored.")
                }
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
            if item.repeatRule == .none {
                item.seriesEndDate = nil
                item.repeatInterval = 1
                item.repeatWeekdays = []
            }

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
                                            categoryHue: hue(fromColor: value("color", "category_color")),
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
            return headerless(rows)
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

    /// Supplies the header for a paste that never had one — a bare
    /// `Lab report,CSDS302,…` copied out of a file, or just a list of task
    /// names. The columns are taken to be `authoringHeaders` in order, which
    /// is the order the template, the AI prompt, and every documented example
    /// use, cut to however wide the widest row actually is.
    ///
    /// Commentary is dropped the same way it is for a headed paste: when some
    /// rows carry real fields, a row holding a single field is a sentence
    /// ("Sure, here you go:") rather than a task. When *every* row holds one
    /// field the paste is a plain list of titles, so all of them stay.
    private static func headerless(_ rows: [[String]]) -> [[String]] {
        let populated = rows.filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        guard let widest = populated.map(\.count).max() else { return rows }
        let kept = widest > 1 ? populated.filter { $0.count > 1 } : populated
        guard !kept.isEmpty else { return rows }
        return [Array(authoringHeaders.prefix(min(widest, authoringHeaders.count)))] + kept
    }

    /// True when `text` is a single CSV data row rather than a sentence
    /// somebody typed, which is what lets the quick-add field accept both.
    ///
    /// Commas alone can't decide it — "Buy milk, eggs, bread" is a task, not a
    /// row — so this insists on a positive signal: a `YYYY-MM-DD` field where
    /// a date belongs, or the run of empty fields that only a generated row
    /// has. Prose reaches neither bar.
    static func looksLikeRow(_ text: String) -> Bool {
        let rows = parse(text)
        guard rows.count == 1, let fields = rows.first, fields.count >= 3 else { return false }
        let trimmed = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let title = trimmed.first, !title.isEmpty else { return false }
        // The header line on its own describes no task, so it isn't one.
        guard title.lowercased() != "title" else { return false }

        let hasDate = trimmed.contains { dayFormatter.date(from: $0) != nil }
        let blanks = trimmed.filter(\.isEmpty).count
        return hasDate || (fields.count >= 6 && blanks >= 2)
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
    /// the task editor would have created them.
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
    /// on import, and including them just invited malformed rows. The sample
    /// rows are chosen to demonstrate the whole `repeat` legend: a one-off, a
    /// weekly, an every-other-week, a monthly, and a row that leaves almost
    /// everything blank.
    static func template() -> String {
        let examples = [
            ["Read chapter 4", "History", "amber", "2026-09-03", "", "", "",
             "Skim the summary first"],
            ["Discussion post", "History", "amber", "2026-09-01", "23:59", "w:tue",
             "2026-12-11", ""],
            ["Lab report", "CSDS302", "blue", "2026-09-04", "17:00", "2w:fri",
             "2026-12-11", "Every other Friday"],
            ["Office hours", "CSDS302", "blue", "2026-09-04", "14:30", "w:thu", "", ""],
            ["Pay rent", "", "", "2026-09-01", "", "m", "", ""],
            ["Buy a lab notebook", "", "", "", "", "", "", ""],
        ]
        var lines = [authoringHeaders.joined(separator: ",")]
        lines.append(contentsOf: examples.map { $0.map(escape).joined(separator: ",") })
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - AI prompt

    private static let promptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        return formatter
    }()

    /// Instructions to paste into a chat with an AI, followed by a
    /// plain-English list of assignments, to get back an importable CSV.
    ///
    /// Everything here is a response to a way this actually failed:
    ///
    /// - **It states today's date.** A model has no reliable idea what day it
    ///   is, so "the essay due next Friday" used to land in the wrong week —
    ///   or in the wrong year.
    /// - **It lists the board's existing categories and their colors**, so a
    ///   generated file joins the categories already in use instead of
    ///   inventing "Hist 101" alongside the "History" that's already there.
    /// - **It asks for only the nine authoring columns.** Listing all sixteen
    ///   and saying "leave these seven blank" reliably produced rows with the
    ///   wrong number of fields.
    /// - **It gives the repeat legend as a table**, which a model copies far
    ///   more accurately than it follows a sentence describing a syntax.
    /// - **It tells the model to ask questions first** rather than inventing
    ///   an end date, a due time, or what "week 3" means.
    static func aiPrompt(categories: [(name: String, color: String)] = [],
                         today: Date = Date()) -> String {
        let legend = repeatLegend
            .map { "  " + $0.code.padding(toLength: 16, withPad: " ", startingAt: 0) + $0.meaning }
            .joined(separator: "\n")

        var existingCategories = ""
        if !categories.isEmpty {
            let listed = categories.map { "  \($0.name) \u{2014} \($0.color)" }.joined(separator: "\n")
            existingCategories = """


            I already use these categories. Reuse them exactly as written, with the \
            color shown, and only invent a new category if something genuinely \
            doesn't fit one of them:
            \(listed)
            """
        }

        return """
        Turn my assignment list into a CSV I can import into StudyBlock, my task app.

        Today is \(promptDateFormatter.string(from: today)). Work out every date from that.

        STEP 1 — ask before you guess.
        If anything is missing or vague — "next Friday", "end of the semester", when \
        a repeating task should stop, which course something belongs to, whether a \
        due time matters — ask me about all of it at once, then wait for my answers. \
        Never invent a date and never use a placeholder. If nothing is unclear, go \
        straight to step 2.

        STEP 2 — reply with ONLY the CSV.
        No commentary above or below it, no code fences, no markdown table.

        The first line is exactly this header:
        \(authoringHeaders.joined(separator: ","))

        Then one line per task, with all \(authoringHeaders.count) fields on every line \
        — write nothing between two commas for a blank value. Only `title` is \
        required. Wrap a field in "double quotes" if it contains a comma.

        Columns, in order:
          title         the task name
          category      course or subject, free text (History, CSDS302, Chores)
          color         red, orange, amber, lime, green, spring, cyan, sky, blue,
                        violet, magenta, or pink — pick one per category and use the
                        same one every time that category appears
          due_date      YYYY-MM-DD. For a repeating task, its FIRST due date.
          due_time      HH:mm on a 24-hour clock (23:59). Blank means sometime that day.
          repeat        a code from the legend below. Blank means it doesn't repeat.
          repeat_until  YYYY-MM-DD, the last day a repeating task runs. Blank means
                        it repeats indefinitely.
          notes         anything else worth keeping. Last on the line on purpose.

        The repeat legend:
        \(legend)
        The number in front is how many, the letter is the unit (d/w/m), and anything
        after the ":" is the weekdays it lands on — weekly only, space-separated, from
        mon tue wed thu fri sat sun.

        Write ONE line per repeating task, never one line per occurrence. StudyBlock \
        creates the individual copies itself. Never write "Discussion post week 1", \
        "Discussion post week 2", and so on.\(existingCategories)

        A valid reply looks exactly like this:
        \(authoringHeaders.joined(separator: ","))
        Essay on the Reformation,History,amber,2026-09-04,23:59,,,"Thesis, outline, then draft"
        Discussion post,History,amber,2026-09-01,23:59,w:tue,2026-12-11,
        Problem set,CSDS302,blue,2026-09-05,,2w:fri,2026-12-11,
        Lecture,CSDS302,blue,2026-09-02,10:00,w:mon wed,2026-12-09,
        Pay rent,,,2026-10-01,,m,,
        Buy a lab notebook,,,,,,,

        Those last two rows are fine as they are: a task with no category, no due \
        date, or no repeat just leaves those fields empty.

        My assignments are:
        """
    }

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
