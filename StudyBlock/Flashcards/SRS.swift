import Foundation

enum SRSGrade: Int, CaseIterable {
    case again = 0
    case hard = 3
    case good = 4
    case easy = 5

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// Classic SM-2 scheduling (the SuperMemo/Anki family): failed cards reset
/// and come back tomorrow; passed cards graduate 1 day → 6 days → interval ×
/// ease factor, with the ease factor drifting per grade (floor 1.3).
enum SRS {
    static func review(_ card: Flashcard, grade: SRSGrade, now: Date = Date(),
                       calendar: Calendar = .current) -> Flashcard {
        var updated = card
        let quality = grade.rawValue

        if quality < 3 {
            updated.repetition = 0
            updated.intervalDays = 1
        } else {
            switch updated.repetition {
            case 0: updated.intervalDays = 1
            case 1: updated.intervalDays = 6
            default: updated.intervalDays = (updated.intervalDays * updated.easeFactor).rounded()
            }
            updated.repetition += 1
        }

        let q = Double(quality)
        updated.easeFactor = max(1.3, updated.easeFactor + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)))

        let today = calendar.startOfDay(for: now)
        updated.dueDate = calendar.date(byAdding: .day, value: Int(updated.intervalDays), to: today)
        return updated
    }

    /// "1d" / "6d" / "2w" hint shown on each grade button.
    static func previewLabel(for card: Flashcard, grade: SRSGrade) -> String {
        let days = Int(review(card, grade: grade).intervalDays)
        switch days {
        case ..<7: return "\(days)d"
        case ..<30: return "\(days / 7)w"
        default: return "\(days / 30)mo"
        }
    }
}
