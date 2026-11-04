import SwiftUI

enum AppStyle {
    static let accent = Color(red: 0.34, green: 0.29, blue: 0.85)
    static let teal = Color(red: 0.12, green: 0.58, blue: 0.56)

    static func scheduleAccent(_ schedule: TaskSchedule) -> Color {
        if case .allDay = schedule { return teal }
        return accent
    }

    static func accentText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.70, green: 0.66, blue: 1.0) : accent
    }

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.10, blue: 0.12) : Color(red: 0.975, green: 0.975, blue: 0.98)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : .white
    }

    static func scheduleLabel(_ schedule: TaskSchedule) -> String {
        switch schedule {
        case .none: return "添加日期"
        case .week(let start): return "\(dayLabel(start))这一周"
        case .allDay, .timed:
            guard let days = schedule.dayRange(in: .current) else { return "添加日期" }
            let last = days.upperBound.adding(days: -1)
            return days.lowerBound == last ? dayLabel(days.lowerBound) : "\(dayLabel(days.lowerBound)) – \(dayLabel(last))"
        }
    }

    static func weekdayLabel(_ day: Day) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"][calendar.component(.weekday, from: day.date(in: .current)) - 1]
    }

    static func dayLabel(_ day: Day) -> String {
        let parts = day.rawValue.split(separator: "-")
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let prefix = Int(parts[0]) == currentYear ? "" : "\(parts[0])年"
        return "\(prefix)\(Int(parts[1])!)月\(Int(parts[2])!)日"
    }

    static func monthLabel(_ day: Day) -> String {
        let parts = day.rawValue.split(separator: "-")
        return "\(parts[0])年\(Int(parts[1])!)月"
    }
}
