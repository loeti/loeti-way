import Foundation

/// Text helpers for dates and names, shared by CLI output and generated files.
public enum Format {
    /// Swiss date format, e.g. 03.02.2027.
    public static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    /// Whole calendar days from `now` to `date`; negative once it has passed.
    public static func daysLeft(until date: Date, now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    public static func expiry(_ date: Date?, now: Date) -> String {
        guard let date else { return "ohne Ablaufdatum" }
        let days = daysLeft(until: date, now: now)
        switch days {
        case ..<0: return "abgelaufen am \(Format.date(date))"
        case 0: return "läuft heute ab"
        case 1: return "läuft morgen ab (\(Format.date(date)))"
        default: return "läuft ab am \(Format.date(date)) (in \(days) Tagen)"
        }
    }
}

/// Lowercase ASCII name with dashes, used for default agent names.
public enum Slug {
    public static func make(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            let isAlnum = (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39)
            if isAlnum {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
