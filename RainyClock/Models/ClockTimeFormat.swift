import Foundation

/// A display preference only: never changes a Date or the scheduled alarm time.
enum ClockTimeFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case twelveHour, twentyFourHour
    var id: String { rawValue }
    var title: String { String(localized: self == .twelveHour ? "clock_format_12" : "clock_format_24") }

    func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        let chinese = locale.language.languageCode?.identifier == "zh"
        formatter.amSymbol = chinese ? "上午" : "AM"
        formatter.pmSymbol = chinese ? "下午" : "PM"
        formatter.dateFormat = self == .twentyFourHour ? "HH:mm" : (chinese ? "a h:mm" : "h:mm a")
        return formatter.string(from: date)
    }

    func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted) + " " + time(date)
    }
}

extension ClockTimeFormat {
    /// The clock split into digits and day period, so a widget can size them
    /// separately. `joined` is exactly what `time(_:locale:timeZone:)` returns.
    struct Parts: Equatable, Sendable {
        var clock: String          // "7:30" / "07:30"
        var period: String?        // "上午"/"下午" or "AM"/"PM"; nil in 24-hour
        var periodLeads: Bool      // true for zh
        var joined: String {       // must equal time(_:locale:timeZone:)
            guard let period else { return clock }
            return periodLeads ? "\(period) \(clock)" : "\(clock) \(period)"
        }
    }

    /// Same rules as `time(_:)`: en_US_POSIX formatter, Gregorian calendar,
    /// `chinese = locale.language.languageCode?.identifier == "zh"`.
    func parts(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> Parts {
        let chinese = locale.language.languageCode?.identifier == "zh"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.amSymbol = chinese ? "上午" : "AM"
        formatter.pmSymbol = chinese ? "下午" : "PM"
        if self == .twentyFourHour {
            formatter.dateFormat = "HH:mm"
            return Parts(clock: formatter.string(from: date), period: nil, periodLeads: false)
        }
        formatter.dateFormat = "h:mm"
        let clock = formatter.string(from: date)
        formatter.dateFormat = "a"
        return Parts(clock: clock, period: formatter.string(from: date), periodLeads: chinese)
    }
}
