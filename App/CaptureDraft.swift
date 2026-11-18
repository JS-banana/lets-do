import Foundation
import SwiftUI

/// The main sheet and quick window edit one recoverable capture draft.
@MainActor
final class CaptureDraft: ObservableObject {
    @Published var content = TaskWriting() { didSet { persist() } }
    @Published var plan = ScheduleForm() {
        didSet {
            if !restoring && !applyingTitleDate { explicitDate = true; dateFromTitle = false }
            persist()
        }
    }
    @Published private(set) var status = ""
    @Published var mainWindowID: UUID?
    private(set) var id = UUID()
    private weak var store: TaskStore?
    private var path: String?
    private var restoring = false
    private var explicitDate = false
    private(set) var dateFromTitle = false
    private var applyingTitleDate = false
    private var pendingSchedule: TaskSchedule?

    func begin(schedule: TaskSchedule = .none) {
        guard store != nil else { pendingSchedule = schedule; return }
        if !content.hasText && !explicitDate {
            plan = ScheduleForm(schedule: schedule)
            explicitDate = false
        }
    }

    /// Quick entry proposes the date named in its title until the user picks one.
    /// Removing the phrase returns to the entry's own default.
    func recognizeDate(fallback: TaskSchedule, today: Day) {
        guard !explicitDate || dateFromTitle else { return }
        let recognized = TitleDate.schedule(in: content.title, today: today)
        guard recognized != nil || dateFromTitle else { return }
        applyingTitleDate = true
        defer { applyingTitleDate = false }
        let schedule = recognized ?? fallback
        if plan.schedule != schedule { plan = ScheduleForm(schedule: schedule) }
        dateFromTitle = recognized != nil
        explicitDate = dateFromTitle
    }

    /// Keeps the entry's default plan and stops recognising dates in this draft.
    func ignoreTitleDate(fallback: TaskSchedule) {
        plan = ScheduleForm(schedule: fallback)
    }

    func attach(to store: TaskStore, tasks: [TaskSnapshot]) {
        self.store = store
        if path != store.directory.path {
            restoring = true
            mainWindowID = nil
            path = store.directory.path
            content = TaskWriting(); plan = ScheduleForm(); id = UUID(); status = ""; explicitDate = false; dateFromTitle = false
            do {
                for draft in try store.drafts().filter({ $0.kind == .capture }) {
                    if tasks.contains(where: { $0.id == draft.taskID }) { try store.removeDraft(id: draft.id) }
                    else {
                        id = draft.id
                        content = TaskWriting(title: draft.title, body: draft.body, formatting: draft.formatting)
                        plan = ScheduleForm(schedule: draft.captureSchedule ?? .none)
                        explicitDate = draft.captureSchedule != nil
                        status = "已恢复上次的输入草稿"
                        break
                    }
                }
            } catch { status = "草稿恢复失败，原文件保留：\(error.localizedDescription)" }
            restoring = false
        }
        if let schedule = pendingSchedule { pendingSchedule = nil; begin(schedule: schedule) }
    }

    func detach() {
        TaskWritingEditor.finishEditing()
        persist()
        store = nil
    }

    @discardableResult
    func persist() -> Bool {
        if restoring { return true }
        guard let store else { return !content.hasText }
        do {
            if !content.hasText { try store.removeDraft(id: id); status = "" }
            else {
                try store.saveDraft(LocalDraft(formatVersion: 1, id: id, taskID: id, kind: .capture,
                    title: content.title, body: content.body, parentIDs: [], updatedAt: Date(),
                    captureSchedule: plan.schedule, formatting: content.formatting))
                status = "草稿已保存在此设备"
            }
            return true
        } catch {
            status = "草稿未能保存：\(error.localizedDescription)"
            return false
        }
    }

    func save(using model: PrototypeModel) -> Bool {
        TaskWritingEditor.finishEditing()
        let savedID = id
        guard model.create(title: content.title, id: savedID, schedule: plan.schedule,
                           body: content.body, formatting: content.formatting) else { return false }
        var cleanupMessage = ""
        do { try store?.removeDraft(id: savedID) }
        catch { cleanupMessage = "任务已保存；草稿清理失败，重启会按 UUID 核对。" }
        restoring = true
        content = TaskWriting(); plan = ScheduleForm(); id = UUID(); status = cleanupMessage
        explicitDate = false; dateFromTitle = false
        restoring = false
        return true
    }
}

/// Recognises a Chinese date phrase at the start or end of a quick-entry title.
/// The title itself is never rewritten; the result only proposes a plan.
enum TitleDate {
    private static let weekdays: [(String, Int)] = [("一", 0), ("二", 1), ("三", 2), ("四", 3), ("五", 4), ("六", 5), ("日", 6), ("天", 6)]

    private enum Meaning {
        case offset(Int)
        case weekday(Int, week: Int?) // week nil: the next such day from today
        case wholeWeek(Int)
    }

    private static let phrases: [(String, Meaning)] = {
        var values: [(String, Meaning)] = [
            ("今天", .offset(0)), ("今日", .offset(0)), ("今晚", .offset(0)),
            ("明天", .offset(1)), ("明日", .offset(1)), ("明晚", .offset(1)),
            ("后天", .offset(2)), ("大后天", .offset(3)),
            ("本周", .wholeWeek(0)), ("这周", .wholeWeek(0)), ("下周", .wholeWeek(1)),
            ("周末", .weekday(5, week: nil)), ("本周末", .weekday(5, week: 0)),
            ("这周末", .weekday(5, week: 0)), ("下周末", .weekday(5, week: 1))
        ]
        for (prefix, week) in [("", nil), ("本", 0), ("这", 0), ("下", 1)] as [(String, Int?)] {
            for unit in ["周", "星期", "礼拜"] {
                for (name, index) in weekdays { values.append((prefix + unit + name, .weekday(index, week: week))) }
            }
        }
        return values.sorted { $0.0.count > $1.0.count }
    }()

    private static let leadingDate = try! NSRegularExpression(pattern: #"^(\d{1,2})(?:月(\d{1,2})[日号]?|/(\d{1,2}))"#)
    private static let trailingDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})(?:月(\d{1,2})[日号]?|/(\d{1,2}))$"#)

    static func schedule(in title: String, today: Day) -> TaskSchedule? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let day = monthDay(in: text, today: today) { return .singleDay(day) }
        guard let meaning = phrases.first(where: { text.hasPrefix($0.0) || text.hasSuffix($0.0) })?.1,
              let monday = today.weekStart else { return nil }
        switch meaning {
        case .offset(let days):
            return today.addingIfPossible(days: days).map { .singleDay($0) }
        case .wholeWeek(let weeks):
            return monday.addingIfPossible(days: 7 * weeks).map { .week(start: $0) }
        case .weekday(let index, let week):
            guard var day = monday.addingIfPossible(days: 7 * (week ?? 0) + index) else { return nil }
            if week == nil && day < today {
                // "周末" said on Sunday still means this weekend.
                if index == 5, today == monday.addingIfPossible(days: 6) { return .singleDay(today) }
                guard let next = day.addingIfPossible(days: 7) else { return nil }
                day = next
            }
            return .singleDay(day)
        }
    }

    /// "11月20日", "11月20" and "11/20" mean the next such date, this year or next.
    private static func monthDay(in text: String, today: Day) -> Day? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = leadingDate.firstMatch(in: text, range: range) ?? trailingDate.firstMatch(in: text, range: range)
        else { return nil }
        func number(_ group: Int) -> Int? {
            Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
        }
        guard let month = number(1), let date = number(2) ?? number(3),
              let year = Int(today.rawValue.prefix(4)) else { return nil }
        for candidate in [year, year + 1] {
            let raw = String(format: "%04d-%02d-%02d", candidate, month, date)
            guard let day = try? Day(raw) else { return nil }
            if day >= today { return day }
        }
        return nil
    }
}
