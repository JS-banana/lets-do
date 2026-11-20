import SwiftUI

/// Import stays a quiet icon until the connected list has reminders to bring in.
struct MacReminderImportEntry: View {
    @ObservedObject var reminders: MacReminders
    let open: () -> Void
    /// The last count read without a refresh in flight; a refresh clears candidates first.
    @State private var settled = 0

    private var current: Int { reminders.selectedListID == nil ? 0 : reminders.manualCandidates.count }

    var body: some View {
        entry(count: reminders.busy ? settled : current)
            .onChange(of: reminders.busy, initial: true) { _, busy in if !busy { settled = current } }
            .onChange(of: current) { _, value in if !reminders.busy { settled = value } }
    }

    @ViewBuilder
    private func entry(count: Int) -> some View {
        if count > 0 {
            Button("提醒事项有 \(count) 条新事项", systemImage: "tray.and.arrow.down.fill", action: open)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("reminderImportNew")
        } else if !reminders.autoSync {
            Button("从提醒事项导入", systemImage: "tray.and.arrow.down", action: open)
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("从提醒事项导入")
                .accessibilityIdentifier("reminderImport")
        }
    }
}

/// A paused or blocked sync is otherwise visible only inside Settings, so the settings entry carries it.
struct MacReminderSettingsHint: View {
    @ObservedObject var reminders: MacReminders

    var body: some View {
        if reminders.syncNeedsAttention {
            Label("提醒事项同步需处理", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("reminderSyncAttention")
        } else {
            Text("本机存储").font(.caption).foregroundStyle(.secondary)
        }
    }
}

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
            Text(reminders.autoSync
                 ? "普通提醒会自动加入待办。带链接或重复的提醒可在这里手动导入；重复提醒只复制到 Mac，原系列保留。"
                 : "导入的任务会出现在「待办」，可在这里安排日期。原提醒和截止日期保留在提醒事项中。")
                .foregroundStyle(.secondary)
            MacReminderListPicker(reminders: reminders)
            if reminders.authorized, reminders.selectedListID != nil {
                Divider()
                if reminders.busy {
                    ProgressView("正在读取清单…")
                } else if reminders.manualCandidates.isEmpty && reminders.message == nil {
                    Text("这份清单里没有可导入的未完成事项。").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(reminders.manualCandidates) { item in
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
                                    Button("导入") { reminders.importCandidate(item) }
                                        .accessibilityLabel("导入\(item.title)")
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

struct MacReminderSyncSettings: View {
    @ObservedObject var reminders: MacReminders
    private struct Preview: Equatable {
        let store: ObjectIdentifier
        let list: MacReminderList
        let push: Int
        let imports: Int
    }
    @State private var preview: Preview?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提醒事项").font(.headline)
            Toggle("与提醒事项同步", isOn: Binding(get: { reminders.autoSync }, set: { on in
                Task {
                    if on { await prepare() }
                    else { await reminders.setAutoSync(false) }
                }
            }))
            .toggleStyle(.switch)
            .disabled(!reminders.autoSync && (!reminders.authorized || reminders.selectedListID == nil || reminders.busy))
            .accessibilityIdentifier("autoSyncReminders")
            MacReminderListPicker(reminders: reminders)
            Text("Let’s Do 运行时会同步任务标题、安排和完成状态，也会导入所选清单的新提醒。手机上勾选完成会回写；改名、改日期或删除提醒会保留 Mac 原任务。切换清单会暂停同步。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if reminders.autoSync {
                Text("已同步 \(reminders.syncSummary.synced) 条")
                if reminders.syncSummary.needsReview > 0 { Text("\(reminders.syncSummary.needsReview) 条需要核对") }
                if reminders.syncSummary.unlinked > 0 { Text("\(reminders.syncSummary.unlinked) 条未自动关联或导入") }
            }
            if let message = reminders.message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .task { await reminders.refresh(forPreview: true) }
        .alert("开启提醒事项同步？", isPresented: $confirming, presenting: preview) { previous in
            Button("开启同步") { Task { await prepare(accepting: previous) } }
            Button("取消", role: .cancel) {}
        } message: { proposed in
            Text("将把 \(proposed.push) 条未完成任务新建到「\(proposed.list.sourceTitle) · \(proposed.list.title)」，并导入 \(proposed.imports) 条提醒。已关联或曾导入的提醒会在原清单核对。Mac 回收任务也会删除已同步的原提醒，包括暂停期间回收的任务。")
        }
    }

    private func prepare(accepting previous: Preview? = nil) async {
        guard !reminders.busy, !reminders.autoSync, let store = reminders.attachedStoreID,
              let list = reminders.lists.first(where: { $0.id == reminders.selectedListID }),
              previous == nil || (previous?.store == store && previous?.list.scope == list.scope) else { return }
        await reminders.refresh(forPreview: true)
        guard !Task.isCancelled, reminders.attachedStoreID == store,
              reminders.selectedListID == list.id, reminders.canPreviewSync else { return }
        let counts = reminders.syncPreview()
        guard reminders.canPreviewSync else { return }
        let current = Preview(store: store, list: list, push: counts.push, imports: counts.importCount)
        if current == previous || (counts == (0, 0) && !reminders.hasPriorLinks) {
            await reminders.setAutoSync(true, expecting: list.scope)
        } else {
            preview = current
            confirming = true
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
                Text(reminders.autoSync ? "提醒事项同步" : "发送到提醒事项").font(.title2.bold())
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
                if reminders.autoSync {
                    Text("请先在系统提醒事项里核对原清单。").foregroundStyle(.secondary)
                    if reminders.canResetHandoff(for: task.id) {
                        Button("重新同步…") { confirmingRetry = true }.disabled(sending)
                    } else {
                        Text("读取到原清单和当前清单后，可以重新同步。").font(.callout)
                        Button("刷新状态") { Task { await reminders.refresh() } }.disabled(reminders.busy)
                    }
                } else {
                    Text("发送结果待核实。请先查看原清单，再刷新关联状态。").foregroundStyle(.secondary)
                    HStack {
                        Button("刷新状态") { Task { await reminders.refresh() } }
                        if reminders.canRetryHandoff(for: task.id) {
                            Button("核对后重新发送…") { confirmingRetry = true }
                        }
                    }.disabled(reminders.busy || sending)
                }
            case .notSent:
                if !reminders.autoSync {
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
            }
            if let message = reminders.message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .padding(22).frame(minWidth: 420, idealWidth: 470)
        .confirmationDialog(reminders.autoSync ? "重新同步这项任务？" : "已在原清单里核实这条提醒仍未出现？", isPresented: $confirmingRetry) {
            Button(reminders.autoSync ? "重新同步" : "重新发送到原清单") {
                Task {
                    guard !sending, isCurrent() else { return }
                    sending = true
                    defer { sending = false }
                    if reminders.autoSync { await reminders.resetHandoff(task.id) }
                    else { await reminders.retryHandoff(task.id, due: nil) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(reminders.autoSync
                 ? "原提醒可能已被删除或复制。会先在当前清单查找同一任务链接，唯一匹配时恢复关联，找不到才按当前安排新建。"
                 : "请先等系统提醒事项完成同步。Let’s Do 会再检查一次原清单；如果原提醒延迟到达，仍可能出现两条。")
        }
        .task { await reminders.refresh() }
    }
}
