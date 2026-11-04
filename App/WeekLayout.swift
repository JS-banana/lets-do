import Foundation

/// A day's timed tasks, clipped to its real midnight boundaries. Offsets use
/// elapsed minutes so 23/25-hour daylight-saving days retain both occurrences.
struct DayTimelineLayout {
    struct Block: Identifiable {
        let id: UUID
        let startMinute: Double
        let endMinute: Double
        let lane: Int
        var laneCount: Int
    }

    let minuteCount: Double
    let blocks: [Block]

    static func make(day: Day, tasks: [CalendarTask], timeZone: TimeZone) -> Self {
        let midnight = day.date(in: timeZone)
        let nextMidnight = day.adding(days: 1).date(in: timeZone)
        let minuteCount = nextMidnight.timeIntervalSince(midnight) / 60
        var seen = Set<UUID>()
        let intervals: [(UUID, Double, Double)] = tasks.compactMap { task in
            guard seen.insert(task.id).inserted,
                  case let .timed(start, end, _) = task.schedule,
                  start < end, start < nextMidnight, midnight < end else { return nil }
            return (task.id, max(start, midnight).timeIntervalSince(midnight) / 60,
                    min(end, nextMidnight).timeIntervalSince(midnight) / 60)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.uuidString < $1.0.uuidString
        }

        var result: [Block] = []
        var group: [Block] = []
        var laneEnds: [Double] = []
        var groupEnd = -Double.infinity
        for (id, start, end) in intervals {
            if start >= groupEnd {
                result += group.map { block in
                    var block = block; block.laneCount = laneEnds.count; return block
                }
                group = []; laneEnds = []
            }
            let lane = laneEnds.firstIndex(where: { $0 <= start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            group.append(Block(id: id, startMinute: start, endMinute: end, lane: lane, laneCount: 1))
            groupEnd = max(groupEnd, end)
        }
        result += group.map { block in
            var block = block; block.laneCount = laneEnds.count; return block
        }
        return Self(minuteCount: minuteCount, blocks: result)
    }
}
