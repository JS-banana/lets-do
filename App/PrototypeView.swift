import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PrototypeView: View {
    @ObservedObject var model: PrototypeModel
    @ObservedObject private var captureSession: CaptureDraft
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var quickEntryFocused: Bool
    @State private var mainWindowID = UUID()
    #endif
    @State private var showTrash = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var filter = TaskFilter.unscheduled
    @State private var earlierExpanded = true
    @State private var completedExpanded = false
    #if os(macOS)
    @State private var section = Workspace.week
    @State private var destination = MacDestination.today
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingUnscheduled = false
    @State private var showingReminderImport = false
    #else
    @State private var section = Workspace.month
    @State private var phoneTab = PhoneTab.today
    private enum PhoneTab: String { case today = "今天", inbox = "收集箱", calendar = "日历" }
    #endif
    @State private var weekList: WeekTaskList?
    @State private var calendarDetailDay: Day?
    @State private var calendarDay = Day(date: Date(), timeZone: .current)
    @State private var capturing = false
    @State private var showingInfo = false
    @State private var showingWidgets = false
    @State private var document: ArchiveDocument?
    @State private var exporting = false
    @State private var importing = false

    init(model: PrototypeModel) {
        self.model = model
        captureSession = model.capture
    }

    private enum Workspace: String, CaseIterable {
        case month = "月", week = "周"
    }

    private var hasCaptureDraft: Bool { captureSession.content.hasText }
    #if os(macOS)
    private var captureInThisWindow: Bool { captureSession.mainWindowID == mainWindowID }
    #endif

    private enum TaskFilter: String, CaseIterable {
        case all = "全部", unscheduled = "未安排", completed = "已完成"
    }

    private var listed: [TaskSnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.tasks.filter { task in
            guard showTrash ? task.deletedAt != nil : task.deletedAt == nil else { return false }
            guard query.isEmpty || task.title.localizedStandardContains(query) else { return false }
            if showTrash { return true }
            switch filter {
            case .all: return true
            case .unscheduled: return task.schedule == .none && !task.isCompleted
            case .completed: return task.isCompleted
            }
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            macWorkspace
                .sheet(isPresented: $showingReminderImport) {
                    MacReminderImportView(reminders: model.reminders)
                }
            #else
            phoneWorkspace
            #endif
        }
        .tint(AppStyle.accentText(colorScheme))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .background(AppStyle.canvas(colorScheme))
        #if !os(macOS)
        .sheet(isPresented: $capturing) {
            CaptureSheet(content: $captureSession.content, plan: $captureSession.plan, draftStatus: captureSession.status, loaded: model.loaded,
                         cancel: { capturing = false }, save: saveCapture)
        }
        #endif
        .sheet(isPresented: $showingInfo) { storageInfo }
        .onChange(of: model.storePath) { _, _ in
            search = ""
            #if os(macOS)
            showingReminderImport = false
            #endif
        }
        .onChange(of: calendarDay) { _, day in
            if calendarDetailDay != nil { calendarDetailDay = day }
            #if os(macOS)
            if destination == .calendar && !hasCaptureDraft {
                captureSession.begin(schedule: contextCaptureSchedule)
            }
            #endif
        }
        .onOpenURL(perform: openURL)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Lets-Do-backup") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let archive = try TaskArchive.decode(Data(contentsOf: url))
                model.perform { try $0.restoreIntoEmptyLocalStore(archive) }
            } catch { model.error = error.localizedDescription }
        }
    }

    #if os(macOS)
    private enum MacDestination: String, CaseIterable {
        case today = "今天", inbox = "收集箱", calendar = "日历"
        case all = "全部任务", completed = "已完成", trash = "回收站"

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .inbox: "tray"
            case .calendar: "calendar"
            case .all: "list.bullet"
            case .completed: "checkmark.circle"
            case .trash: "trash"
            }
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var macWorkspace: some View {
        let newTaskAction: (() -> Void)? = model.loaded ? { beginContextCapture() } : nil
        return GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columns) {
                macSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 240)
            } detail: {
                HStack(spacing: 0) {
                    if (model.selected == nil && !captureInThisWindow) || geometry.size.width >= 1040 {
                        macContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if captureInThisWindow {
                        if geometry.size.width >= 1040 { Divider() }
                        CaptureSheet(content: $captureSession.content, plan: $captureSession.plan,
                                     draftStatus: captureSession.status, loaded: model.loaded,
                                     cancel: { captureSession.mainWindowID = nil }, save: {
                            if captureSession.save(using: model) { captureSession.mainWindowID = nil }
                        }, embedded: true)
                            .frame(maxWidth: geometry.size.width >= 1040 ? 360 : .infinity)
                    } else if let task = model.selected {
                        if geometry.size.width >= 1040 { Divider() }
                        TaskDetail(model: model, task: task, compact: geometry.size.width < 1040)
                            .id(task.id)
                            .id(model.store.map(ObjectIdentifier.init))
                            .frame(maxWidth: geometry.size.width >= 1040 ? 340 : .infinity)
                    }
                }
                .toolbar { macToolbar }
                .searchable(text: $search, prompt: "搜索全部任务")
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: geometry.size.width, initial: true) { previous, width in
                if previous == width || (previous < 840) != (width < 840) {
                    columns = width < 840 ? .detailOnly : .all
                }
            }
            .onChange(of: model.selection) { _, selected in
                if selected != nil { captureSession.mainWindowID = nil }
            }
            .onChange(of: model.loaded) { _, loaded in
                if loaded {
                    captureSession.begin(schedule: contextCaptureSchedule)
                }
            }
            .onChange(of: search) { _, value in
                if !value.isEmpty {
                    if captureInThisWindow { captureSession.mainWindowID = nil }
                    model.selection = nil
                }
            }
            .overlay(alignment: .bottom) { completionNotice.padding(16) }
        }
        .focusedSceneValue(\.newTask, newTaskAction)
    }

    private func navigate(_ next: MacDestination) {
        TaskWritingEditor.finishEditing()
        captureSession.mainWindowID = nil
        model.selection = nil
        search = ""
        completedExpanded = false
        weekList = nil
        destination = next
        captureSession.begin(schedule: contextCaptureSchedule)
    }

    private var macSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { destination }, set: { navigate($0) })) {
                ForEach([MacDestination.today, .inbox, .calendar], id: \.self) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                        .padding(.vertical, 5).accessibilityIdentifier("nav-\(item)")
                }
                Section {
                    ForEach([MacDestination.all, .completed], id: \.self) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                            .padding(.vertical, 5).accessibilityIdentifier("nav-\(item)")
                    }
                }
                Section {
                    Label("回收站", systemImage: "trash").tag(MacDestination.trash)
                        .padding(.vertical, 5).accessibilityIdentifier("nav-trash")
                }
            }.listStyle(.sidebar)
            Divider().padding(.horizontal, 14)
            Button { showingInfo = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("设置").foregroundStyle(.primary)
                        Text(StoreSession.isDesktopLocalBuild || StoreSession.isLocalBuild ? "本机存储" : "iCloud 与存储")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("openSettings")
        }
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if destination == .calendar && query.isEmpty && weekList == nil {
                Picker("日历视图", selection: Binding(get: { section }, set: { calendarDetailDay = nil; section = $0 })) {
                    ForEach([Workspace.week, .month], id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 148).accessibilityIdentifier("calendarViews")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if destination == .calendar && query.isEmpty && weekList == nil {
                Button { showingUnscheduled.toggle() } label: { Image(systemName: "tray.and.arrow.down") }
                    .help("待安排任务").accessibilityLabel("待安排任务")
                    .popover(isPresented: $showingUnscheduled) { unscheduledTasks }
            }
        }
    }

    @ViewBuilder
    private var macContent: some View {
        Group {
            if !model.loaded {
                VStack(spacing: 14) {
                    Text(model.status).foregroundStyle(.secondary)
                    Button("重新打开任务库") { Task { await model.start() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if destination == .calendar && query.isEmpty {
                VStack(spacing: 0) {
                    plannerContent.frame(maxHeight: .infinity)
                    calendarDayPanel
                }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    macTaskCollection(today: Day(date: context.date, timeZone: .current))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.loaded && query.isEmpty && destination != .completed && destination != .trash && weekList != .previousWeeks { quickEntry }
        }
    }

    private var quickEntrySchedule: TaskSchedule {
        let day = Day(date: Date(), timeZone: .current)
        return .allDay(start: day, endExclusive: day.addingIfPossible(days: 1) ?? day)
    }

    private var contextCaptureSchedule: TaskSchedule {
        switch destination {
        case .today: return quickEntrySchedule
        case .calendar:
            if weekList == .pending { return .week(start: calendarDay) }
            if weekList == .previousWeeks { return .none }
            return .allDay(start: calendarDay, endExclusive: calendarDay.addingIfPossible(days: 1) ?? calendarDay)
        default: return .none
        }
    }

    private var quickEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    quickEntryFocused = true
                } label: { Image(systemName: "plus").font(.system(size: 20, weight: .regular)) }
                    .buttonStyle(.plain).accessibilityLabel("添加任务")
                TextField("添加任务", text: Binding(get: { captureSession.content.title }, set: { title in
                    // Refresh an empty draft's implicit date before its first character,
                    // including when the field has kept focus across midnight.
                    captureSession.begin(schedule: contextCaptureSchedule)
                    captureSession.content.title = title
                }))
                    .textFieldStyle(.plain).font(.body).focused($quickEntryFocused)
                    .accessibilityIdentifier("quickTaskTitle").onSubmit(saveQuickEntry)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            .background(AppStyle.accent.opacity(colorScheme == .dark ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(quickEntryFocused ? AppStyle.accentText(colorScheme).opacity(0.55) : Color.clear, lineWidth: 1) }
            if hasCaptureDraft && captureSession.plan.schedule != contextCaptureSchedule {
                Text(captureSession.plan.schedule == .none ? "添加到收集箱" : "添加到" + AppStyle.scheduleLabel(captureSession.plan.schedule))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = captureSession.plan.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 16)
            } else if captureSession.status.contains("失败") || captureSession.status.contains("未能") {
                Text(captureSession.status).font(.caption).foregroundStyle(.red).padding(.leading, 16)
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(AppStyle.canvas(colorScheme))
        .onChange(of: quickEntryFocused) { _, focused in
            if focused {
                dismissWindow(id: "capture")
                captureSession.mainWindowID = nil
                captureSession.begin(schedule: contextCaptureSchedule)
            }
        }
    }

    private func activateInlineCapture() {
        TaskWritingEditor.finishEditing()
        dismissWindow(id: "capture")
        captureSession.mainWindowID = nil
    }

    private func saveQuickEntry() {
        activateInlineCapture()
        guard !captureSession.content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard captureSession.plan.error == nil else { return }
        if captureSession.save(using: model) {
            model.selection = nil
            captureSession.begin(schedule: contextCaptureSchedule)
            quickEntryFocused = true
        }
    }

    private func collection() -> [TaskSnapshot] {
        if !query.isEmpty { return model.active.filter { $0.title.localizedStandardContains(query) } }
        switch destination {
        case .inbox: return model.active.filter { $0.schedule == .none }
        case .completed: return model.active.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .trash: return model.tasks.filter { $0.deletedAt != nil }
        default: return model.active
        }
    }

    private func macTaskCollection(today: Day) -> some View {
        let tasks = destination == .today && query.isEmpty ? [] : collection()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(query.isEmpty ? destination.rawValue : "搜索结果").font(.system(size: 26, weight: .semibold))
                        Spacer()
                        if !query.isEmpty {
                            Button("结束搜索") { search = "" }.buttonStyle(.borderless)
                        } else if destination == .inbox && model.loaded {
                            Button("从提醒事项导入", systemImage: "tray.and.arrow.down") { showingReminderImport = true }
                                .buttonStyle(.borderless)
                        }
                    }
                    if destination == .today && query.isEmpty {
                        Text(AppStyle.dayLabel(today) + " · " + AppStyle.weekdayLabel(today))
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if !query.isEmpty {
                        Text("“\(query)” · \(tasks.count) 项").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if destination == .today && query.isEmpty {
                    todaySections(on: today)
                } else {
                    collectionRows(tasks: tasks, today: today)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.background(AppStyle.canvas(colorScheme))
            .accessibilityIdentifier(query.isEmpty ? "collection-\(destination)" : "searchResults")
    }

    @ViewBuilder
    private func collectionRows(tasks: [TaskSnapshot], today: Day) -> some View {
        let unfinished = tasks.filter { !$0.isCompleted }
        let finished = tasks.filter(\.isCompleted)
        let separated = query.isEmpty && destination != .completed && destination != .trash
        if tasks.isEmpty || (separated && unfinished.isEmpty) {
            macCollectionEmpty(hasFinished: !finished.isEmpty)
        }
        LazyVStack(spacing: 0) {
            ForEach(separated ? unfinished : tasks) { task in macTaskRow(task, today: today) }
        }
        if separated && !finished.isEmpty {
            DisclosureGroup("已完成 · \(finished.count)", isExpanded: $completedExpanded) {
                LazyVStack(spacing: 0) { ForEach(finished) { task in macTaskRow(task, today: today) } }
                    .padding(.top, 8)
            }.font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func macCollectionEmpty(hasFinished: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(!query.isEmpty ? "没有找到匹配任务" : hasFinished ? "当前任务都完成了" : destination == .today ? "今天还没有安排" : destination == .inbox ? "收集箱是空的" : destination == .completed ? "还没有已完成任务" : destination == .trash ? "回收站是空的" : "从第一件事开始")
                .font(.title3.weight(.medium))
            if query.isEmpty && (destination == .today || destination == .inbox || destination == .all) {
                HStack(spacing: 16) {
                    Text("在下方记下一件事，回车即可添加。").font(.callout).foregroundStyle(.secondary)
                    if destination == .today { Button("去收集箱看看") { navigate(.inbox) }.buttonStyle(.borderless) }
                }
            } else if !query.isEmpty { Text("试试更短的标题关键词。").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 36)
    }

    private func macTaskRow(_ task: TaskSnapshot, today: Day, showSchedule: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleCompletion(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(task.isCompleted ? AppStyle.accentText(colorScheme) : Color.secondary.opacity(0.7))
                    .frame(width: 30, height: 38)
            }.buttonStyle(.plain).disabled(task.deletedAt != nil)
                .accessibilityLabel(task.isCompleted ? "设为未完成：\(task.title)" : "完成：\(task.title)")
            Button { showingUnscheduled = false; model.selection = task.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .strikethrough(task.isCompleted).fixedSize(horizontal: false, vertical: true)
                    if (showSchedule || destination != .today || !query.isEmpty) && task.schedule != .none {
                        Text(AppStyle.scheduleLabel(task.schedule)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = task.currentNote?.body, !note.isEmpty {
                        Text(note.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if task.heads.count > 1 {
                        Label("\(task.heads.count) 个正文分支", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开任务：\(task.title)").accessibilityValue(AppStyle.scheduleLabel(task.schedule))
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(model.selection == task.id ? AppStyle.accent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) { Divider().padding(.leading, 46) }
        .draggable(task.id.uuidString)
        .contextMenu {
            if task.deletedAt != nil {
                Button("恢复任务") { model.perform { try $0.restoreTask(id: task.id) } }
            } else {
                if !task.isCompleted { planningActions(for: task, today: today) }
                Button(task.isCompleted ? "设为未完成" : "完成任务") { model.toggleCompletion(task) }
                Button("移入回收站", role: .destructive) { model.perform { try $0.moveToTrash(id: task.id) } }
            }
        }
        .accessibilityIdentifier("task-\(task.id.uuidString)")
    }

    private var unscheduledTasks: some View {
        let tasks = model.active.filter { !$0.isCompleted && $0.schedule == .none }
        return VStack(alignment: .leading, spacing: 12) {
            Text("待安排任务").font(.headline)
            Text("拖到日历日期，或打开详情设置安排。").font(.caption).foregroundStyle(.secondary)
            if tasks.isEmpty { Text("没有未安排任务").foregroundStyle(.secondary).padding(.vertical, 20) }
            ScrollView { LazyVStack(spacing: 0) { ForEach(tasks) { task in macTaskRow(task, today: Day(date: Date(), timeZone: .current)) } } }
        }.padding(20).frame(width: 340, height: 360)
    }

    private func beginContextCapture() {
        search = ""
        captureSession.begin(schedule: contextCaptureSchedule)
        presentCapture(schedule: captureSession.plan.schedule)
    }

    @ViewBuilder
    private var completionNotice: some View {
        if let feedback = model.completionFeedback {
            HStack(spacing: 12) {
                Image(systemName: feedback.previousValue ? "arrow.uturn.backward" : "checkmark.circle.fill")
                    .foregroundStyle(AppStyle.accentText(colorScheme))
                Text(feedback.previousValue ? "已设为未完成" : "已完成").font(.callout)
                Text(feedback.title).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: 200, alignment: .leading)
                Button("撤销") { model.undoCompletion() }.buttonStyle(.borderless).accessibilityIdentifier("undoCompletion")
                Button { model.completionFeedback = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭完成提示")
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5) }
            .task(id: feedback.id) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled && model.completionFeedback?.id == feedback.id { model.completionFeedback = nil }
            }
        }
    }
    #else
    private var phoneWorkspace: some View {
        NavigationStack {
            TabView(selection: $phoneTab) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if model.loaded { todaySections(on: Day(date: context.date, timeZone: .current)) }
                            else { Text(model.status).foregroundStyle(.secondary) }
                        }.padding().padding(.bottom, 76)
                    }
                }
                .overlay(alignment: .bottomTrailing) { floatingCapture }
                .tabItem { Label("今天", systemImage: "sun.max") }.tag(PhoneTab.today)
                VStack(spacing: 0) {
                    if weekList == nil {
                        Picker("日历视图", selection: Binding(get: { section }, set: { section = $0; calendarDetailDay = nil })) {
                            Text("周").tag(Workspace.week)
                            Text("月").tag(Workspace.month)
                        }.pickerStyle(.segmented).padding(.horizontal)
                    }
                    plannerContent
                    if section == .month { calendarDayPanel }
                }
                .overlay(alignment: .bottomTrailing) { if section == .month && calendarDetailDay == nil { floatingCapture } }
                .tabItem { Label("日历", systemImage: "calendar") }.tag(PhoneTab.calendar)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        searchField
                        if !showTrash { filterPicker }
                        if !model.loaded {
                            ProgressView("正在打开任务…").frame(maxWidth: .infinity).padding(.top, 60)
                        } else if listed.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(listed) { task in taskRow(task) }
                            }
                        }
                    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 100)
                }
                .background(AppStyle.canvas(colorScheme))
                .overlay(alignment: .bottomTrailing) { floatingCapture }
                .tabItem { Label("收集箱", systemImage: "tray") }.tag(PhoneTab.inbox)
            }
            .onChange(of: phoneTab) { old, _ in
                if old == .calendar { weekList = nil }
                if old == .inbox { search = ""; filter = .unscheduled; showTrash = false; searchFocused = false }
            }
            .navigationTitle(phoneTab == .inbox ? (showTrash ? "回收站" : filter == .all ? "全部任务" : filter == .completed ? "已完成" : "收集箱") : phoneTab.rawValue)
            .navigationBarTitleDisplayMode(phoneTab == .calendar ? .inline : .large)
            .toolbar {
                if phoneTab == .calendar && section == .month {
                    ToolbarItem(placement: .topBarLeading) {
                        CalendarDateButton(day: Binding(get: { calendarDay }, set: { calendarDay = $0; calendarDetailDay = $0 }),
                                           title: AppStyle.monthLabel(calendarDay))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if phoneTab != .inbox {
                            Button {
                                showTrash = false; filter = .all; phoneTab = .inbox; searchFocused = true
                            } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索全部任务")
                        }
                        toolsMenu
                    }
                }
            }
            .navigationDestination(item: $model.selection) { id in
                if let task = model.tasks.first(where: { $0.id == id }) {
                    TaskDetail(model: model, task: task).id(task.id)
                        .id(model.store.map(ObjectIdentifier.init))
                        .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView("任务暂不可用", systemImage: "tray",
                                           description: Text("请返回列表检查当前账户与同步状态。"))
                }
            }
        }.id(model.storePath)
    }

    private var floatingCapture: some View {
        Button {
            let day: Day? = phoneTab == .today ? Day(date: Date(), timeZone: .current) : phoneTab == .calendar ? calendarDay : nil
            presentCapture(schedule: day.map { .allDay(start: $0, endExclusive: $0.adding(days: 1)) } ?? .none)
        } label: {
            Image(systemName: hasCaptureDraft ? "square.and.pencil" : "plus")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: AppStyle.accent.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain).padding(20)
        .accessibilityLabel(hasCaptureDraft ? "继续输入草稿" : "新建任务")
        .accessibilityIdentifier("newTask").disabled(!model.loaded)
    }
    #endif

    @ViewBuilder
    private func todaySections(on today: Day) -> some View {
        let overview = TodayTasks(model.active, on: today, timeZone: .current)
        if overview.scheduled.isEmpty && overview.earlier.isEmpty {
            Text(overview.finishedToday.isEmpty ? "今天还没有安排" : "今天的任务都完成了")
                .foregroundStyle(.secondary)
            if overview.inboxCount > 0 {
                Button("查看收集箱 · \(overview.inboxCount) 项") { openCollection(.inbox) }
            }
        }
        ForEach(overview.scheduled) { todayRow($0, on: today) }
        if !overview.earlier.isEmpty {
            DisclosureGroup("此前未完成 · \(overview.earlier.count)", isExpanded: $earlierExpanded) {
                LazyVStack(spacing: 2) {
                    ForEach(overview.earlier) { todayRow($0, on: today, earlier: true) }
                }
            }.accessibilityIdentifier("earlierTasks")
        }
        if !overview.finishedToday.isEmpty {
            DisclosureGroup("已完成 · \(overview.finishedToday.count)", isExpanded: $completedExpanded) {
                ForEach(overview.finishedToday) { todayRow($0, on: today) }
            }
        }
    }

    @ViewBuilder
    private func todayRow(_ task: TaskSnapshot, on today: Day, earlier: Bool = false) -> some View {
        #if os(macOS)
        macTaskRow(task, today: today, showSchedule: earlier)
        #else
        taskRow(task)
        #endif
    }

    @ViewBuilder
    private func planningActions(for task: TaskSnapshot, today: Day) -> some View {
        Button("安排到今天") {
            model.perform { try $0.scheduleTask(id: task.id, schedule: .singleDay(today)) }
        }
        if let monday = today.weekStart, task.schedule != .week(start: monday) {
            Button("放入本周待安排") { model.perform { try $0.scheduleTask(id: task.id, schedule: .week(start: monday)) } }
        }
        if task.schedule != .none {
            Button("移到收集箱") { model.perform { try $0.scheduleTask(id: task.id, schedule: .none) } }
        }
    }

    private func openCollection(_ target: AppDestination) {
        TaskWritingEditor.finishEditing()
        model.selection = nil
        search = ""
        earlierExpanded = true
        #if os(macOS)
        navigate(target == .today ? .today : .inbox)
        #else
        capturing = false; showTrash = false; filter = .unscheduled
        phoneTab = target == .today ? .today : .inbox
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索任务标题", text: $search).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("taskSearch")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.padding(11).background(AppStyle.surface(colorScheme), in: RoundedRectangle(cornerRadius: 11))
    }

    private var filterPicker: some View {
        Picker("任务筛选", selection: $filter) {
            ForEach(TaskFilter.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("taskFilter")
    }

    private var taskList: some View {
        Group {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listed.isEmpty {
                emptyState.frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(listed) { task in
                        taskRow(task).tag(task.id).draggable(task.id.uuidString)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.accessibilityIdentifier("taskList")
    }

    private var emptyState: some View {
        let heading = !search.isEmpty ? "没有找到任务" : showTrash ? "回收站是空的"
            : filter == .completed ? "还没有已完成任务" : filter == .unscheduled ? "暂时没有未安排任务" : "收集箱是空的"
        let hint = !search.isEmpty ? "试试更短的标题关键词。" : showTrash ? "移入回收站的任务会保留在这里。"
            : filter == .completed ? "完成的任务会出现在这里。" : "想到什么，点 + 先记下来。"
        return VStack(spacing: 12) {
            Image(systemName: showTrash ? "trash" : search.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 32, weight: .light)).foregroundStyle(AppStyle.accentText(colorScheme).opacity(0.65))
            Text(heading)
                .font(.headline).multilineTextAlignment(.center)
            Text(hint)
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 54)
    }

    private func taskRow(_ task: TaskSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.toggleCompletion(task)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(task.isCompleted ? AppStyle.accentText(colorScheme) : Color.secondary.opacity(0.65))
                    #if os(macOS)
                    .frame(minWidth: 28, minHeight: 36)
                    #else
                    .frame(minWidth: 44, minHeight: 44)
                    #endif
            }.buttonStyle(.plain).disabled(task.deletedAt != nil)
                .accessibilityLabel(task.isCompleted ? "设为未完成：\(task.title)" : "完成：\(task.title)")
            Button { model.selection = task.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        .strikethrough(task.isCompleted).lineLimit(2)
                    if task.schedule != .none {
                        Text(AppStyle.scheduleLabel(task.schedule)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let body = task.currentNote?.body, !body.isEmpty {
                        Text(body.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if task.heads.count > 1 {
                        Label("\(task.heads.count) 个正文分支", systemImage: "arrow.triangle.branch")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .contextMenu { if task.deletedAt == nil && !task.isCompleted { planningActions(for: task, today: Day(date: Date(), timeZone: .current)) } }
        .padding(13)
        .background(model.selection == task.id ? AppStyle.accent.opacity(0.09) : AppStyle.surface(colorScheme),
                    in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("task-\(task.id.uuidString)")
    }

    private var toolsMenu: some View {
        Menu {
            #if os(iOS)
            Button(showTrash ? "返回收集箱" : "查看回收站", systemImage: showTrash ? "tray" : "trash") {
                showTrash.toggle()
                #if os(iOS)
                phoneTab = .inbox
                #endif
            }
            #endif
            Button("存储与同步信息", systemImage: "internaldrive") { showingInfo = true }
            Divider()
            Button("导出独立 JSON 备份", systemImage: "square.and.arrow.up") {
                model.perform { store in document = try ArchiveDocument(data: store.archive().encoded()); exporting = true }
            }.disabled(!model.loaded)
            Button("恢复到空的本地测试库", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(!model.loaded)
            Divider()
            Button("载入固定测试数据") { model.seed() }.accessibilityIdentifier("seedFixtures").disabled(!model.loaded)
            Button(StoreSession.supportsCloudSync ? "检查账户与同步" : "检查本机存储") {
                Task { await model.checkAccountAndStorage() }
            }
                .disabled(model.checkingAccount)
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
                .frame(minWidth: 36, minHeight: 36)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
            .accessibilityLabel("更多操作").accessibilityIdentifier("testMenu")
    }

    private var storageInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button { showingInfo = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭设置").keyboardShortcut(.cancelAction)
                    .frame(minWidth: 28, minHeight: 28)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("iCloud 同步", systemImage: "icloud").font(.headline)
                        if StoreSession.supportsCloudSync {
                            Toggle("使用 iCloud 同步", isOn: Binding(get: { model.cloudSyncEnabled }, set: { enabled in
                                TaskWritingEditor.finishEditing()
                                Task { await model.setCloudSyncEnabled(enabled) }
                            }))
                                .toggleStyle(.switch).disabled(model.checkingAccount)
                                .accessibilityIdentifier("cloudSyncToggle")
                        }
                        HStack(spacing: 8) {
                            if model.checkingAccount { ProgressView().controlSize(.small) }
                            Text(model.cloudAccountTitle).font(.callout.weight(.medium))
                        }.accessibilityIdentifier("cloudAccountStatus")
                        if StoreSession.supportsCloudSync {
                            Text(model.cloudAccountIssue ?? model.status)
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(model.cloudSyncEnabled
                                 ? "关闭后回到本机收集箱。iCloud 中的任务与草稿会保留，再次开启即可访问。"
                                 : "开启后进入独立的 iCloud 任务库。已有本机任务与草稿保留在此设备，不会自动上传。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("当前版本仅保存在这台设备，不会上传到 iCloud。云同步需要使用具备 iCloud 权限的版本。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(StoreSession.supportsCloudSync
                             ? "无需注册应用账号。Mac 与 iPhone 使用系统中同一个 Apple 账户，并在 iCloud 设置中允许 Let’s Do 访问。"
                             : "云同步沿用设备的系统 Apple 账户，无需另注册应用账号。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(StoreSession.supportsCloudSync ? "检查账户与同步" : "检查本机存储") {
                                Task { await model.checkAccountAndStorage() }
                            }
                                .buttonStyle(.bordered).disabled(model.checkingAccount)
                                .accessibilityIdentifier("checkCloudAccount")
                            #if os(macOS)
                            if StoreSession.supportsCloudSync {
                                Button("打开系统设置") {
                                    if !NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) {
                                        model.error = "无法打开系统设置。请从 Apple 菜单进入，再选择 Apple 账户 → iCloud。"
                                    }
                                }.buttonStyle(.borderless)
                            }
                            #endif
                        }
                        #if os(iOS)
                        if StoreSession.supportsCloudSync {
                            Text("在系统“设置”顶部打开 Apple 账户 → iCloud → 查看全部，检查应用权限。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        #endif
                        if model.session?.cloudEnabled == true {
                            DisclosureGroup("本次打开的同步详情") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("最近接收：\(model.cloudSyncStatus.lastImport.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "等待首次接收")")
                                    Text("最近发送：\(model.cloudSyncStatus.lastExport.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "等待首次发送")")
                                    Text("同步由系统安排。这些记录只表示此设备的交换，另一台设备是否收到仍需在那台设备查看。")
                                        .foregroundStyle(.secondary)
                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.callout)
                        }
                    }
                    Divider()
                    HStack {
                        Text("数据与诊断").font(.headline)
                        Spacer()
                        toolsMenu
                    }
                    #if os(macOS)
                    Button("小组件布局预览", systemImage: "rectangle.3.group") { showingWidgets = true }
                        .buttonStyle(.borderless)
                    #endif
                    DisclosureGroup("存储详情") {
                        Text(model.storePath).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.callout)
                    HStack { Text("Let’s Do").font(.callout.weight(.medium)); Spacer(); Text("只管去做").font(.callout).foregroundStyle(.secondary) }
                }.padding(24)
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 580)
        .sheet(isPresented: $showingWidgets) {
            WidgetGalleryView(model: model) { url in
                showingWidgets = false
                showingInfo = false
                NSWorkspace.shared.open(url)
            }
        }
        #else
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var calendarDayPanel: some View {
        if let day = calendarDetailDay {
            Divider()
            CalendarDayTasks(model: model, day: day, create: { beginCapture(day: day) }, close: { calendarDetailDay = nil })
                .frame(height: min(260, max(110, CGFloat(model.scheduled(on: day).count) * 76 + 60)))
                .background(AppStyle.surface(colorScheme))
        }
    }

    @ViewBuilder
    private var plannerContent: some View {
        if let weekList {
            weekTaskList(weekList)
        } else {
            switch section {
            case .week: WeekView(model: model, selectedDay: $calendarDay, create: { beginCapture(day: $0) }, createWeek: {
                captureSession.plan = ScheduleForm(schedule: .week(start: $0.weekStart ?? $0))
                presentCapture(schedule: captureSession.plan.schedule)
            }, inspectDay: { calendarDetailDay = $0 })
            case .month: MonthView(model: model, selectedDay: $calendarDay, create: { beginCapture(day: $0) }, inspectDay: { calendarDetailDay = $0 })
            }
        }
    }

    private func weekTaskList(_ list: WeekTaskList) -> some View {
        let tasks = list.tasks(from: model.active, weekStart: calendarDay, timeZone: .current)
        let today = Day(date: Date(), timeZone: .current)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Button { weekList = nil } label: { Label("返回周历", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                HStack(alignment: .firstTextBaseline) {
                    Text(list.title).font(.title2.bold())
                    if model.loaded { Text("\(tasks.count)").foregroundStyle(.secondary) }
                    #if os(iOS)
                    if list == .pending && model.loaded {
                        Spacer()
                        Button("加入本周", systemImage: "plus") {
                            presentCapture(schedule: .week(start: calendarDay))
                        }
                    }
                    #endif
                }
                Text(list == .previousWeeks ? "\(AppStyle.dayLabel(calendarDay)) 之前" : AppStyle.scheduleLabel(.week(start: calendarDay)))
                    .font(.subheadline).foregroundStyle(.secondary)
                if !model.loaded {
                    Text(model.status).foregroundStyle(.secondary)
                } else if tasks.isEmpty {
                    Text(list == .pending ? "这一周没有待安排任务" : "此前各周没有未完成任务")
                        .foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    todayRow(task, on: today, earlier: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("week-list-\(list.rawValue)")
    }

    private func beginCapture(day: Day? = nil) {
        if let day {
            captureSession.plan = ScheduleForm(schedule: .allDay(start: day, endExclusive: day.addingIfPossible(days: 1) ?? day))
        }
        presentCapture(schedule: day.map { .allDay(start: $0, endExclusive: $0.addingIfPossible(days: 1) ?? $0) } ?? .none)
    }

    private func presentCapture(schedule: TaskSchedule) {
        captureSession.begin(schedule: schedule)
        #if os(macOS)
        TaskWritingEditor.finishEditing()
        quickEntryFocused = false
        dismissWindow(id: "capture")
        model.selection = nil
        captureSession.mainWindowID = mainWindowID
        #else
        capturing = true
        #endif
    }

    private func saveCapture() {
        if captureSession.save(using: model) {
            capturing = false; showTrash = false; search = ""
        }
    }

    private func openURL(_ url: URL) {
        guard let destination = AppDestination(url: url) else { return }
        showingWidgets = false
        showingInfo = false
        #if os(iOS)
        capturing = false
        #endif
        switch destination {
        case .today, .inbox: openCollection(destination)
        case .task(let id):
            #if os(macOS)
            TaskWritingEditor.finishEditing()
            captureSession.mainWindowID = nil
            weekList = nil
            self.destination = .all
            search = ""
            #endif
            model.openTask(id: id)
        case .calendar(let day, let view):
            openCalendar(day: day, view: view)
        case .weekList(let monday, let list):
            openCalendar(day: monday, view: .week)
            weekList = list
        case .capture(let schedule):
            presentCapture(schedule: schedule)
        }
    }

    private func openCalendar(day: Day, view: CalendarPresentation) {
        TaskWritingEditor.finishEditing()
        #if os(macOS)
        captureSession.mainWindowID = nil
        destination = .calendar
        search = ""
        #else
        phoneTab = .calendar
        #endif
        weekList = nil
        calendarDay = day
        section = view == .month ? .month : .week
        calendarDetailDay = view == .week ? nil : day
        model.selection = nil
    }

}

struct CaptureSheet: View {
    @Binding var content: TaskWriting
    @Binding var plan: ScheduleForm
    let draftStatus: String
    let loaded: Bool
    let cancel: () -> Void
    let save: () -> Void
    var embedded = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加任务").font(.headline)
                Spacer()
                Button { TaskWritingEditor.finishEditing(); cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("收起并保留草稿").keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TaskWritingEditor(content: $content, autofocus: true, editable: loaded, minimumHeight: 100)
                    Divider()
                    Button { TaskWritingEditor.finishEditing(); showingDate = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 16)).frame(width: 24)
                            Text(AppStyle.scheduleLabel(plan.schedule)).foregroundStyle(plan.schedule == .none ? Color.secondary : .primary)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                        }.foregroundStyle(.secondary).frame(minHeight: 40)
                        #if os(iOS)
                        .padding(.vertical, 2)
                        #endif
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!loaded).accessibilityIdentifier("captureDate")
                        .popover(isPresented: $showingDate) {
                            TaskDatePopover(schedule: plan.schedule, apply: {
                                plan = ScheduleForm(schedule: $0); return true
                            }, close: { showingDate = false })
                        }
                    if let error = plan.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if !draftStatus.isEmpty {
                        Text(draftStatus).font(.caption).foregroundStyle(draftStatus.contains("失败") || draftStatus.contains("未能") ? Color.red : Color.secondary)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            Divider().padding(.horizontal, 20)
            HStack {
                Text("换行添加备注").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("添加任务", action: save).font(.body.weight(.semibold))
                    .buttonStyle(.borderedProminent).tint(AppStyle.accent)
                    .disabled(!loaded || content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.error != nil)
                    .accessibilityIdentifier("captureSave").keyboardShortcut(.return, modifiers: .command)
            }.padding(20)
        }
        .background(AppStyle.canvas(colorScheme))
        .tint(AppStyle.accentText(colorScheme))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        #if os(macOS)
        .frame(minWidth: embedded ? 0 : 380, maxWidth: embedded ? .infinity : 420,
               minHeight: embedded ? 0 : 380, maxHeight: embedded ? .infinity : 480)
        #else
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        #endif
    }
}

struct TaskDetail: View {
    @ObservedObject var model: PrototypeModel
    let task: TaskSnapshot
    var compact = false
    private let editingStore: TaskStore?
    @Environment(\.colorScheme) private var colorScheme
    @State private var writing = TaskWriting()
    @State private var parents: [UUID] = []
    @State private var baselineWriting = TaskWriting()
    @State private var baselineParents: [UUID] = []
    @State private var noteDraftID = UUID()
    @State private var initialized = false
    @State private var showingSchedule = false
    @State private var showingHistory = false
    #if os(macOS)
    @State private var showingReminderHandoff = false
    #endif
    @State private var needsDraftTitleChoice = false
    @State private var showingDraftTitleChoice = false
    @State private var draftStatus = ""
    @State private var otherDrafts: [LocalDraft] = []

    init(model: PrototypeModel, task: TaskSnapshot, compact: Bool = false) {
        self.model = model
        self.task = task
        self.compact = compact
        editingStore = model.store
        _writing = State(initialValue: TaskWriting(title: task.title, body: task.currentNote?.body ?? "", formatting: task.currentNote?.formatting))
        _parents = State(initialValue: task.currentNote.map { [$0.id] } ?? [])
        _baselineWriting = State(initialValue: TaskWriting(title: task.title, body: task.currentNote?.body ?? "", formatting: task.currentNote?.formatting))
        _baselineParents = State(initialValue: task.currentNote.map { [$0.id] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TaskWritingEditor(content: Binding(get: { writing }, set: {
                        if needsDraftTitleChoice && TaskStore.titleChange($0.title, from: writing.title) != nil {
                            baselineWriting.title = task.title
                            needsDraftTitleChoice = false
                        }
                        writing = $0
                        persistEditorDraft()
                    }), editable: task.deletedAt == nil, minimumHeight: 64)
                    if draftStatus.contains("失败") || draftStatus.contains("未能") {
                        Text(draftStatus).font(.caption).foregroundStyle(.red)
                    }
                    Divider()
                    Button { TaskWritingEditor.finishEditing(); showingSchedule = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 16)).frame(width: 24)
                            Text(dateTitle).font(.body)
                                .foregroundStyle(task.schedule == .none ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }.foregroundStyle(.secondary).frame(minHeight: 40)
                        #if os(iOS)
                        .padding(.vertical, 2)
                        #endif
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(task.deletedAt != nil).help("安排日期").accessibilityIdentifier("editSchedule")
                        .popover(isPresented: $showingSchedule) {
                            TaskDatePopover(schedule: task.schedule, apply: { schedule in
                                model.perform { try $0.scheduleTask(id: task.id, schedule: schedule) }
                            }, close: { showingSchedule = false })
                        }
                    if task.heads.count > 1 || !otherDrafts.isEmpty {
                        Button { TaskWritingEditor.finishEditing(); showingHistory = true } label: {
                            Label(task.heads.count > 1 ? "有 \(task.heads.count) 个正文分支" : "查看其他本机草稿", systemImage: "arrow.triangle.branch")
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    if task.deletedAt != nil {
                        Text("恢复任务后可以继续编辑。").font(.caption).foregroundStyle(.secondary)
                        Button("恢复任务") { model.perform { try $0.restoreTask(id: task.id) } }.buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
            }.accessibilityIdentifier("detail-\(task.id.uuidString)")
            Divider().padding(.horizontal, 20)
            if contentChanged && task.deletedAt == nil {
                HStack {
                    Text(draftStatus.contains("失败") || draftStatus.contains("未能") ? "修改尚未保存" : "草稿已保留在本机")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存", action: saveContent)
                        .buttonStyle(.borderless).accessibilityIdentifier("contentSave")
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(writing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, 20).padding(.top, 12)
            }
            HStack(spacing: 12) {
                if task.deletedAt == nil {
                    Button(role: .destructive) {
                        TaskWritingEditor.finishEditing()
                        guard persistEditorDraft(), hasCurrentStore else { return }
                        if model.perform({ try $0.moveToTrash(id: task.id) }) { model.selection = nil }
                    } label: {
                        Image(systemName: "trash").frame(width: 28, height: 28)
                        #if os(iOS)
                            .padding(8)
                        #endif
                    }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("移入回收站")
                        .accessibilityLabel("移入回收站").accessibilityIdentifier("trashTask")
                }
                Spacer()
                Text("创建于\(task.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("版本记录（\(task.revisions.count)）") {
                        TaskWritingEditor.finishEditing(); showingHistory = true
                    }.disabled(task.revisions.isEmpty && otherDrafts.isEmpty)
                    if task.deletedAt == nil {
                        Button(task.isCompleted ? "标记为未完成" : "标记为完成") {
                            TaskWritingEditor.finishEditing()
                            guard hasCurrentStore else { return }
                            model.toggleCompletion(task)
                        }.accessibilityIdentifier("detailCompletion")
                        #if os(macOS)
                        if !task.isCompleted {
                            Button("发送到提醒事项…") {
                                TaskWritingEditor.finishEditing()
                                guard persistEditorDraft(), hasCurrentStore else { return }
                                showingReminderHandoff = true
                            }
                        }
                        #endif
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28)
                    #if os(iOS)
                        .padding(8)
                    #endif
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize().help("版本记录与任务操作").accessibilityLabel("版本记录与任务操作")
                    .accessibilityIdentifier("taskMore")
                #if os(macOS)
                if compact {
                    Button { closeDetail() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("返回任务列表")
                        .accessibilityLabel("返回任务列表").accessibilityIdentifier("closeTaskDetail")
                }
                #endif
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(AppStyle.canvas(colorScheme))
        #if os(macOS)
        .background(InspectorDismissal(handlesEscape: !showingSchedule && !showingHistory && !showingReminderHandoff) { closeDetail() })
        .sheet(isPresented: $showingReminderHandoff) {
            MacReminderHandoffView(reminders: model.reminders, task: task, isCurrent: { hasCurrentStore })
        }
        #endif
        .onAppear {
            guard !initialized else { return }
            do {
                let drafts = try editingStore?.drafts().filter { $0.kind == .editor && $0.taskID == task.id } ?? []
                if let draft = drafts.first { loadDraft(draft) }
            } catch { draftStatus = "草稿恢复失败，原文件保留：\(error.localizedDescription)" }
            initialized = true
        }
        .sheet(isPresented: $showingHistory) { versionHistory }
        .confirmationDialog("旧草稿和当前任务的标题不同", isPresented: $showingDraftTitleChoice, titleVisibility: .visible) {
            Button("保留当前任务标题") { commitContent(title: nil) }
            Button("使用草稿标题") { commitContent(title: writing.title) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前任务：\(task.title)\n草稿：\(writing.title)")
        }
    }

    private var versionHistory: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("版本记录").font(.headline)
                Spacer()
                Button("关闭") { showingHistory = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(task.revisions.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }) { revision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(revision.body).font(.callout).textSelection(.enabled)
                            Button("恢复此文字，保留旧版本") {
                                TaskWritingEditor.finishEditing()
                                writing.body = revision.body; writing.formatting = revision.formatting
                                parents = task.heads.map(\.id); noteDraftID = UUID()
                                persistEditorDraft(); showingHistory = false
                            }.font(.caption).buttonStyle(.borderless)
                        }
                        Divider()
                    }
                    ForEach(otherDrafts) { draft in
                        Button(draft.updatedAt.formatted() + " · " + String(draft.body.prefix(24))) {
                            loadDraft(draft); showingHistory = false
                            persistEditorDraft()
                        }
                    }
                }
            }
        }.padding(24)
            #if os(macOS)
            .frame(width: 420, height: 440)
            #else
            .presentationDetents([.medium, .large])
            #endif
    }

    private var contentChanged: Bool {
        writing != baselineWriting || Set(parents) != Set(baselineParents)
    }

    private var dateTitle: String {
        let label = AppStyle.scheduleLabel(task.schedule)
        guard let days = task.schedule.dayRange(in: .current),
              days.upperBound == days.lowerBound.adding(days: 1) else { return label }
        let today = Day(date: Date(), timeZone: .current)
        if days.lowerBound == today { return "今天 · \(label)" }
        if days.lowerBound == today.adding(days: 1) { return "明天 · \(label)" }
        return "\(label) · \(AppStyle.weekdayLabel(days.lowerBound))"
    }

    private func saveContent() {
        TaskWritingEditor.finishEditing()
        guard hasCurrentStore else { return }
        if needsDraftTitleChoice {
            if TaskStore.titleChange(writing.title, from: task.title) == nil { commitContent(title: nil) }
            else { showingDraftTitleChoice = true }
            return
        }
        commitContent(title: TaskStore.titleChange(writing.title, from: baselineWriting.title))
    }

    private func commitContent(title: String?) {
        guard hasCurrentStore else { return }
        let savedID = noteDraftID
        guard model.perform({
            try $0.updateContent(id: task.id, title: title, revisionID: savedID,
                                 body: writing.body, formatting: writing.formatting, parentIDs: parents)
        }) else { return }
        if let saved = model.tasks.first(where: { $0.id == task.id }) {
            writing = TaskWriting(title: saved.title, body: saved.currentNote?.body ?? "", formatting: saved.currentNote?.formatting)
            parents = saved.currentNote.map { [$0.id] } ?? []
        }
        baselineWriting = writing
        baselineParents = parents
        needsDraftTitleChoice = false
        noteDraftID = UUID()
        otherDrafts.removeAll { $0.id == savedID }
        do { try editingStore?.removeDraft(id: savedID); draftStatus = "" }
        catch { draftStatus = "任务已保存；草稿清理失败，原文件保留。" }
    }

    private func loadDraft(_ draft: LocalDraft) {
        guard hasCurrentStore else { return }
        TaskWritingEditor.finishEditing()
        let title = draft.editorTitle(current: task.title)
        writing = TaskWriting(title: title.text, body: draft.body, formatting: draft.formatting)
        baselineWriting.title = title.baseline
        needsDraftTitleChoice = title.needsChoice
        if task.revisions.contains(where: { $0.id == draft.id }) {
            noteDraftID = UUID(); parents = [draft.id]
        } else { noteDraftID = draft.id; parents = draft.parentIDs }
        draftStatus = "已恢复本机草稿；远端更新不会替换正在输入的文字"
        do {
            otherDrafts = try editingStore?.drafts().filter { $0.kind == .editor && $0.taskID == task.id && $0.id != draft.id } ?? []
        } catch { draftStatus = "当前草稿已恢复，其他草稿读取失败：\(error.localizedDescription)" }
    }

    private var hasCurrentStore: Bool {
        model.loaded && editingStore != nil && model.store === editingStore
    }

    @discardableResult
    private func closeDetail() -> Bool {
        TaskWritingEditor.finishEditing()
        guard persistEditorDraft() else { return false }
        model.selection = nil
        return true
    }

    @discardableResult
    private func persistEditorDraft() -> Bool {
        guard initialized, hasCurrentStore, let store = editingStore else { return false }
        do {
            let saved = model.tasks.first { $0.id == task.id } ?? task
            let savedParents = saved.currentNote.map { [$0.id] } ?? []
            if !contentChanged || (writing.title == saved.title && writing.body == (saved.currentNote?.body ?? "") && writing.formatting == saved.currentNote?.formatting && Set(parents) == Set(savedParents)) {
                try store.removeDraft(id: noteDraftID); draftStatus = ""
            } else {
                try store.saveDraft(LocalDraft(formatVersion: 1, id: noteDraftID, taskID: task.id, kind: .editor,
                                               title: writing.title, body: writing.body, parentIDs: parents, updatedAt: Date(),
                                               formatting: writing.formatting, originalTitle: needsDraftTitleChoice ? nil : baselineWriting.title))
                draftStatus = "修改已保存在此设备；点击保存后更新任务"
            }
            return true
        } catch {
            draftStatus = "草稿未能保存：\(error.localizedDescription)"
            return false
        }
    }
}

#if os(macOS)
/// Observe clicks without placing a transparent hit target over the workspace.
private struct InspectorDismissal: NSViewRepresentable {
    let handlesEscape: Bool
    let dismiss: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak view, coordinator = context.coordinator] event in
            guard let view, let window = view.window, event.window === window else { return event }
            if event.type == .keyDown {
                guard coordinator.handlesEscape, event.keyCode == 53,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                _ = coordinator.dismiss()
                return nil
            }
            guard !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            return coordinator.dismiss() ? event : nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.handlesEscape = handlesEscape
    }
    func makeCoordinator() -> Coordinator { Coordinator(handlesEscape: handlesEscape, dismiss: dismiss) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var dismiss: () -> Bool
        var handlesEscape: Bool
        var monitor: Any?
        init(handlesEscape: Bool, dismiss: @escaping () -> Bool) {
            self.handlesEscape = handlesEscape
            self.dismiss = dismiss
        }
    }
}
#endif
