import SwiftUI
import WidgetKit

struct TaskEntry: TimelineEntry, Sendable {
    let date: Date
    let tasks: [CalendarTask]
    let namespace: String
    let message: String
    var unavailable = false
}

struct TaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskEntry {
        TaskEntry(date: Date(), tasks: [], namespace: "", message: "")
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (TaskEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)) }
        else { getTimeline(in: context) { completion($0.entries[0]) } }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TaskEntry>) -> Void) {
        Task { @MainActor in
            do {
                let session = try await StoreSession.forExtension()
                let store = try TaskStore(directory: session.directory(), isExtension: true, session: session)
                defer { try? store.close() }
                let tasks = try store.snapshots().filter { $0.deletedAt == nil }.map {
                    CalendarTask(id: $0.id, title: $0.title, schedule: $0.schedule, isCompleted: $0.isCompleted, preview: $0.currentNote?.body ?? "")
                }
                store.record("widget.timeline", outcome: "read-local")
                let now = Date()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let dates = [now] + (1...7).compactMap {
                    calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))
                }
                let entries = dates.map {
                    TaskEntry(date: $0, tasks: tasks, namespace: session.namespace,
                              message: session.cloudEnabled ? "本机完成 · 打开应用后同步" : "")
                }
                completion(Timeline(entries: entries, policy: .atEnd))
            } catch {
                let entry = TaskEntry(date: Date(), tasks: [], namespace: "", message: "打开 Let’s Do 后继续查看任务", unavailable: true)
                completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
            }
        }
    }
}

struct TaskWidgetView: View {
    let entry: TaskEntry
    var mode: CalendarWidgetMode = .today
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WidgetCalendarView(date: entry.date, tasks: entry.tasks, mode: mode, family: family,
                           message: entry.message, unavailable: entry.unavailable, storeNamespace: entry.namespace)
            .containerBackground(for: .widget) { AppStyle.surface(colorScheme) }
    }
}

struct TodayTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodoM0Tasks", provider: TaskProvider()) { TaskWidgetView(entry: $0) }
            .configurationDisplayName("今天的任务")
            .description("查看今天和此前未完成的任务，直接勾选完成，或快速记下新的待办。")
            .contentMarginsDisabled()
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WeekPlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodoM0Week", provider: TaskProvider()) { TaskWidgetView(entry: $0, mode: .week) }
            .configurationDisplayName("本周计划")
            .description("查看周一至周日的安排和本周尚未完成的任务，点击日期打开当天清单。")
            .contentMarginsDisabled()
            #if os(macOS)
            .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
            #else
            .supportedFamilies([.systemLarge])
            #endif
    }
}

struct MonthPlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodoM0Month", provider: TaskProvider()) { TaskWidgetView(entry: $0, mode: .month) }
            .configurationDisplayName("月历总览")
            .description("查看整月的任务分布，点击日期继续安排。")
            .contentMarginsDisabled()
            #if os(macOS)
            .supportedFamilies([.systemLarge, .systemExtraLarge])
            #else
            .supportedFamilies([.systemLarge])
            #endif
    }
}

@main
struct TodoWidgets: WidgetBundle {
    var body: some Widget {
        TodayTasksWidget()
        WeekPlanWidget()
        MonthPlanWidget()
    }
}
