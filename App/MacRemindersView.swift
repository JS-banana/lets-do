#if os(macOS)
import SwiftUI

struct MacReminderImportView: View {
    @ObservedObject var reminders: MacReminders
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("从提醒事项导入").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("所选待办的标题和备注会加入收集箱，原提醒和截止日期保留在提醒事项中。")
                .foregroundStyle(.secondary)
            MacReminderListPicker(reminders: reminders)
            if reminders.authorized, reminders.selectedListID != nil {
                Divider()
                if reminders.busy {
                    ProgressView("正在读取清单…")
                } else if reminders.candidates.isEmpty && reminders.message == nil {
                    Text("这份清单里没有可导入的未完成事项。").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(reminders.candidates) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                        if !item.notes.isEmpty {
                                            Text(item.notes).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        if let due = item.dueLabel {
                                            Text("原截止：\(due)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("加入收集箱") { reminders.importCandidate(item) }
                                        .accessibilityLabel("将\(item.title)加入收集箱")
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            if let message = reminders.message { Text(message).font(.callout).textSelection(.enabled) }
            Spacer(minLength: 0)
        }
        .padding(22).frame(minWidth: 420, idealWidth: 490, minHeight: 330, idealHeight: 400)
        .task { await reminders.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reminders.refresh() } }
        }
    }
}

struct MacReminderListPicker: View {
    @ObservedObject var reminders: MacReminders

    var body: some View {
        if reminders.authorized {
            HStack {
                Picker("提醒事项清单", selection: Binding(
                    get: { reminders.selectedListID },
                    set: { id in Task { await reminders.selectList(id) } }
                )) {
                    Text("请选择清单").tag(nil as String?)
                    ForEach(reminders.lists) { list in
                        Text("\(list.sourceTitle) · \(list.title)").tag(Optional(list.id))
                    }
                }
                Button("刷新", systemImage: "arrow.clockwise") { Task { await reminders.refresh() } }
                    .labelStyle(.iconOnly)
            }.disabled(reminders.busy)
            if reminders.lists.isEmpty && !reminders.busy {
                Text("没有可用的可写清单。请先在系统提醒事项中创建清单，然后刷新。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("要在 iPhone 上使用，请选择 iCloud 账户下的清单。").font(.callout).foregroundStyle(.secondary)
            }
        } else if reminders.canRequestPermission {
            Button("允许访问提醒事项") { Task { await reminders.requestPermission() } }
                .disabled(reminders.busy)
        } else {
            Text("请在「系统设置 → 隐私与安全性 → 提醒事项」中允许 Let’s Do 访问，再回来刷新。")
            Button("重新检查权限") { Task { await reminders.refresh() } }
                .disabled(reminders.busy)
        }
    }
}
#endif
