import SwiftUI

/// A date's tasks stay inside the current calendar, rather than becoming a third workspace.
struct CalendarDayTasks: View {
    @ObservedObject var model: PrototypeModel
    let day: Day
    let create: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(AppStyle.dayLabel(day) + " · " + AppStyle.weekdayLabel(day)).font(.headline)
                Text("\(model.scheduled(on: day).count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: create) { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("在这一天新建任务")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("收起当天任务").accessibilityIdentifier("closeDayTasks")
            }
            if model.scheduled(on: day).isEmpty {
                Text("这一天没有安排").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.scheduled(on: day)) { task in
                            TaskAgendaRow(task: task, complete: { model.toggleCompletion(task) }) { model.selection = task.id }
                        }
                    }
                }
            }
        }.padding(16).accessibilityIdentifier("dayTasks-\(day.rawValue)")
    }
}

struct TaskAgendaRow: View {
    let task: TaskSnapshot
    let complete: () -> Void
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: complete) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(task.isCompleted ? AppStyle.accentText(colorScheme) : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain)
                .accessibilityLabel(task.isCompleted ? "设为未完成：\(task.title)" : "完成：\(task.title)")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.body.weight(.medium)).strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body = task.currentNote?.body, !body.isEmpty {
                        Text(body.replacingOccurrences(of: "\n", with: " ")).font(.subheadline)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开任务：\(task.title)")
                .accessibilityIdentifier("day-task-\(task.id.uuidString)")
        }.padding(.vertical, 8).overlay(alignment: .bottom) { Divider().padding(.leading, 42) }
    }
}
