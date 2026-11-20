import SwiftUI

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
