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
struct MacReminderHandoffView: View {
    @ObservedObject var reminders: MacReminders
    let task: TaskSnapshot
    let isCurrent: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var includesDue = false
    @State private var due = Date()
    @State private var sending = false
    @State private var confirmingRetry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("发送到提醒事项").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(task.title).font(.headline)
            if let list = reminders.handoffListLabel(for: task.id) {
                Text("原清单：\(list)").font(.callout).foregroundStyle(.secondary)
            }
            if !reminders.authorized && reminders.handoffStatus(for: task.id) != .notSent {
                MacReminderListPicker(reminders: reminders)
            }
            switch reminders.handoffStatus(for: task.id) {
            case .sent:
                Label("这项任务已发送", systemImage: "checkmark.circle")
                Text("在 iPhone 的提醒事项里完成后，下次 Mac 读取到该状态时，会完成这里的任务。")
                    .foregroundStyle(.secondary)
            case .needsReview:
                Text("发送结果待核实。请先查看原清单，再刷新关联状态。").foregroundStyle(.secondary)
                HStack {
                    Button("刷新状态") { Task { await reminders.refresh() } }
                    if reminders.canRetryHandoff(for: task.id) {
                        Button("核对后重新发送…") { confirmingRetry = true }
                    }
                }.disabled(reminders.busy || sending)
            case .notSent:
                Text("发送已保存的标题。你可以单独设置提醒事项的截止日。").foregroundStyle(.secondary)
                MacReminderListPicker(reminders: reminders)
                if reminders.authorized, reminders.selectedListID != nil {
                    Toggle("设置提醒事项的截止日", isOn: $includesDue)
                    if includesDue {
                        DatePicker("截止日", selection: $due, displayedComponents: [.date])
                    }
                    Button("发送") {
                        guard !sending, isCurrent() else { return }
                        sending = true
                        let day = includesDue ? Day(date: due, timeZone: .current) : nil
                        Task {
                            defer { sending = false }
                            guard isCurrent() else { return }
                            await reminders.sendTask(task.id, due: day)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || reminders.busy || task.deletedAt != nil || task.isCompleted || !isCurrent())
                }
            }
            if let message = reminders.message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .padding(22).frame(minWidth: 420, idealWidth: 470)
        .confirmationDialog("已在原清单里核实这条提醒仍未出现？", isPresented: $confirmingRetry) {
            Button("重新发送到原清单") {
                Task {
                    guard !sending, isCurrent() else { return }
                    sending = true
                    defer { sending = false }
                    await reminders.retryHandoff(task.id, due: nil)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先等系统提醒事项完成同步。Let’s Do 会再检查一次原清单；如果原提醒延迟到达，仍可能出现两条。")
        }
        .task { await reminders.refresh() }
    }
}
#endif
