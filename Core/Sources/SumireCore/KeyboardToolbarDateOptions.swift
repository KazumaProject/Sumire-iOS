import Foundation

/// Date strings exposed by Android Sumire's `select_date` toolbar shortcut.
public enum KeyboardToolbarDateOptions {
    public static func strings(
        for date: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }

        return [
            format("M/d"),
            format("yyyy/MM/dd"),
            format("M月d日(EEE)"),
            "令和\(year - 2018)年\(month)月\(day)日",
            String(format: "R%d/%02d/%02d", locale: locale, year - 2018, month, day),
            format("EEEE")
        ]
    }
}
