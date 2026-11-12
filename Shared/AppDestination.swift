import Foundation

enum CalendarPresentation: String, Equatable, Sendable { case week, month, agenda }

enum AppDestination: Equatable, Sendable {
    case today
    case todo
    case task(UUID)
    case calendar(Day, CalendarPresentation)
    case weekList(Day, WeekTaskList)
    case capture(TaskSchedule)

    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "M0URLScheme") as? String ?? "todom0"
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .today: parts.host = "open"; parts.path = "/today"
        case .todo: parts.host = "open"; parts.path = "/todo"
        case .task(let id): parts.host = "task"; parts.path = "/\(id.uuidString)"
        case .calendar(let day, let view):
            parts.host = "calendar"; parts.path = "/\(day.rawValue)"
            parts.queryItems = [URLQueryItem(name: "view", value: view.rawValue)]
        case .weekList(let monday, let list):
            parts.host = "calendar"; parts.path = "/\(monday.rawValue)"
            parts.queryItems = [URLQueryItem(name: "view", value: list.rawValue)]
        case .capture(let schedule):
            parts.host = "capture"
            if case .week(let start) = schedule { parts.queryItems = [URLQueryItem(name: "week", value: start.rawValue)] }
            else if let day = schedule.dayRange(in: .current)?.lowerBound {
                parts.queryItems = [URLQueryItem(name: "day", value: day.rawValue)]
            }
        }
        // All components above are app-owned constants, canonical days or UUIDs.
        return parts.url!
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme.lowercased(), parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let queries = parts.queryItems ?? []
        guard Set(queries.map(\.name)).count == queries.count else { return nil }
        switch parts.host?.lowercased() {
        case "open":
            guard queries.isEmpty else { return nil }
            switch path {
            case ["today"]: self = .today
            case ["todo"], ["inbox"]: self = .todo
            default: return nil
            }
        case "task":
            guard path.count == 1, let id = UUID(uuidString: path[0]), queries.isEmpty else { return nil }
            self = .task(id)
        case "calendar":
            guard path.count == 1, let day = try? Day(path[0]),
                  queries.allSatisfy({ $0.name == "view" }),
                  queries.allSatisfy({ $0.value != nil }),
                  let monthStart = try? Day(String(day.rawValue.prefix(7)) + "-01"),
                  monthStart.addingIfPossible(days: -6) != nil,
                  monthStart.addingIfPossible(days: 42) != nil else { return nil }
            let value = queries.first?.value ?? "week"
            if let view = CalendarPresentation(rawValue: value) {
                self = .calendar(day, view)
            } else if let list = WeekTaskList(rawValue: value), day.weekStart == day {
                self = .weekList(day, list)
            } else { return nil }
        case "capture":
            guard path.isEmpty, queries.count <= 1 else { return nil }
            if let query = queries.first {
                guard let value = query.value, let day = try? Day(value) else { return nil }
                switch query.name {
                case "day":
                    guard let end = day.addingIfPossible(days: 1) else { return nil }
                    self = .capture(.allDay(start: day, endExclusive: end))
                case "week":
                    guard let start = day.weekStart,
                          let schedule = try? TaskSchedule.week(start: start).validated() else { return nil }
                    self = .capture(schedule)
                default: return nil
                }
            } else { self = .capture(.none) }
        default: return nil
        }
    }
}
