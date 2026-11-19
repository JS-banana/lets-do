import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var captureSession: CaptureDraft
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var quickEntryFocused: Bool
    @FocusState private var macSearchFocused: Bool
    @State private var macSearchExpanded = false
    @State private var mainWindowID = UUID()
    @State private var search = ""
    @State private var earlierExpanded = true
    @State private var destination = Destination.today
    @State private var section = Workspace.week
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingReminderImport = false
    @State private var calendarDrawer: CalendarDrawer?
    @State private var calendarDay = Day(date: Date(), timeZone: .current)
    @State private var showingInfo = false

    init(model: AppModel) {
        self.model = model
        captureSession = model.capture
    }

    private enum Workspace: String, CaseIterable {
        case month = "月", week = "周"
    }

    private var hasCaptureDraft: Bool { captureSession.content.hasText }
    private var captureInThisWindow: Bool { captureSession.mainWindowID == mainWindowID }

    private enum Destination: String, CaseIterable {
        case today = "今天", calendar = "日历", todo = "待办", completed = "已完成", trash = "回收站"

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .calendar: "calendar"
            case .todo: "list.bullet"
            case .completed: "checkmark.circle"
            case .trash: "trash"
            }
        }

        var acceptsNewTasks: Bool { self == .today || self == .calendar || self == .todo }
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var destinationSelection: Binding<Destination> {
        Binding(get: { destination }, set: { navigate($0) })
    }

    private func navigate(_ next: Destination) {
        TaskWritingEditor.finishEditing()
        captureSession.mainWindowID = nil
        calendarDrawer = nil
        macSearchExpanded = false
        macSearchFocused = false
        model.selection = nil
        search = ""
        destination = next
        captureSession.begin(schedule: contextCaptureSchedule)
    }

    private func collection(in page: Destination, matching query: String) -> [TaskSnapshot] {
        if !query.isEmpty {
            let searchable = page == .trash ? model.tasks.filter { $0.deletedAt != nil } : model.active
            return searchable.filter { $0.title.localizedStandardContains(query) }
        }
        switch page {
        case .todo:
            return model.active.filter { !$0.isCompleted }
        case .completed:
            return model.active.filter(\.isCompleted)
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .trash:
            return model.tasks.filter { $0.deletedAt != nil }
        case .today, .calendar:
            return []
        }
    }

    private func collectionEmptyTitle(in page: Destination, matching query: String) -> String {
        if !query.isEmpty { return "没有找到匹配任务" }
        switch page {
        case .completed: return "还没有已完成任务"
        case .trash: return "回收站是空的"
        default: return "没有待办任务"
        }
    }

    private var searchPrompt: String {
        destination == .trash ? "搜索回收站" : "搜索任务标题"
    }

    private func rowScheduleLabel(for task: TaskSnapshot) -> String {
        task.schedule == .none ? "未安排" : AppStyle.scheduleLabel(task.schedule)
    }

    private func showsCollectionSchedule(for task: TaskSnapshot) -> Bool {
        // The grouped to-do list names unscheduled tasks in its section header.
        if destination == .todo && query.isEmpty { return task.schedule != .none }
        return task.schedule != .none && (destination != .today || !query.isEmpty)
    }

    var body: some View {
        Group {
            macWorkspace
                .sheet(isPresented: $showingReminderImport) {
                    MacReminderImportView(reminders: model.reminders)
                }
        }
        .tint(AppStyle.accentText(colorScheme))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .background(AppStyle.canvas(colorScheme))
        .sheet(isPresented: $showingInfo) {
            SettingsView(model: model, close: { showingInfo = false })
        }
        .onChange(of: model.storePath) { _, _ in
            search = ""
            showingReminderImport = false
        }
        .onChange(of: calendarDay) { _, _ in
            // A calendar cell can change the day and open capture with its own schedule.
            if destination == .calendar && !captureInThisWindow && !hasCaptureDraft {
                captureSession.begin(schedule: contextCaptureSchedule)
            }
        }
        .onOpenURL(perform: openURL)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private enum CalendarDrawer: Equatable {
        case day
        case week(WeekTaskList)
    }

    private var visibleCalendarDrawer: CalendarDrawer? {
        destination == .calendar && query.isEmpty && model.loaded ? calendarDrawer : nil
    }

    private var macWorkspace: some View {
        let newTaskAction: (() -> Void)? = model.loaded ? { beginContextCapture() } : nil
        return GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columns) {
                macSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 240)
            } detail: {
                macContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        macDrawer(width: min(342, max(280, geometry.size.width * 0.40)))
                    }
                    .toolbar { macToolbar(windowWidth: geometry.size.width) }
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
        .task {
            guard ProcessInfo.processInfo.environment["LETSDO_UNIT_TEST_HOST"] != "1" else { return }
            GlobalCaptureHotKey.shared.install { [openWindow, model] in model.openQuickCapture(openWindow) }
        }
    }

    private var drawerIsOpen: Bool {
        captureInThisWindow || model.selected != nil || visibleCalendarDrawer != nil
    }

    private var macCalendarDateControls: some View {
        let isWeek = section == .week
        let monday = calendarDay.weekStart ?? calendarDay
        let sunday = monday.addingIfPossible(days: 6) ?? monday
        let title = isWeek ? weekToolbarTitle(from: monday, through: sunday) : AppStyle.monthLabel(calendarDay)
        return HStack(spacing: 10) {
            Picker("日历视图", selection: Binding(get: { section }, set: { calendarDrawer = nil; section = $0 })) {
                ForEach([Workspace.week, .month], id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize().accessibilityIdentifier("calendarViews")
            CalendarDateButton(day: $calendarDay, title: title, minimumHeight: 30)
                .accessibilityIdentifier(isWeek ? "calendarWeek" : "calendarMonth")
            MacCalendarNavigation(selectedDay: $calendarDay, isWeek: isWeek) { delta in
                if isWeek {
                    if let day = calendarDay.addingIfPossible(days: delta * 7) { calendarDay = day }
                } else if let day = MonthView.shiftedMonth(from: calendarDay, by: delta) {
                    calendarDay = day
                }
            }
        }
        .fixedSize()
    }

    private func weekToolbarTitle(from firstDay: Day, through lastDay: Day) -> String {
        if firstDay.rawValue.prefix(7) == lastDay.rawValue.prefix(7), let date = Int(lastDay.rawValue.suffix(2)) {
            return "\(AppStyle.dayLabel(firstDay).dropLast())–\(date)日"
        }
        return "\(AppStyle.dayLabel(firstDay)) – \(AppStyle.dayLabel(lastDay))"
    }

    private var macWeekPendingButton: some View {
        let monday = calendarDay.weekStart ?? calendarDay
        let count = WeekTaskList.pending.tasks(from: model.active, weekStart: monday, timeZone: .current).count
        let isOpen = calendarDrawer == .week(.pending)
        return Button { calendarDrawer = isOpen ? nil : .week(.pending) } label: {
            Label(count == 0 ? "待安排" : "待安排 \(count)", systemImage: "list.bullet")
                .foregroundStyle(isOpen ? AppStyle.accentText(colorScheme) : .primary)
        }
        .help("查看本周待安排")
        .accessibilityLabel("本周待安排")
        .accessibilityValue("\(count) 项")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityIdentifier("showWeekPending")
    }

    private func macDrawer(width: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            if drawerIsOpen {
                Group {
                    if captureInThisWindow {
                        CaptureSheet(content: $captureSession.content, plan: $captureSession.plan,
                                     draftStatus: captureSession.status, loaded: model.loaded,
                                     cancel: { _ = closeCaptureDrawer() }, save: {
                            if captureSession.save(using: model) { captureSession.mainWindowID = nil }
                        }, embedded: true, outsideDismiss: closeCaptureDrawer)
                    } else if let task = model.selected {
                        TaskDetail(model: model, task: task, inDrawer: true)
                            .id(task.id)
                            .id(model.store.map(ObjectIdentifier.init))
                    } else if let drawer = visibleCalendarDrawer {
                        macCalendarAgenda(drawer)
                    }
                }
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background {
                    Rectangle()
                        .fill(.thickMaterial)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.16),
                                radius: 12, x: -5, y: 0)
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier("workspaceDrawer")
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.24), value: drawerIsOpen)
    }

    private func closeCaptureDrawer() -> Bool {
        guard captureInThisWindow else { return true }
        TaskWritingEditor.finishEditing()
        guard captureSession.persist() else { return false }
        captureSession.mainWindowID = nil
        return true
    }

    private func macCalendarAgenda(_ drawer: CalendarDrawer) -> some View {
        let day = calendarDay
        let monday = day.weekStart ?? day
        let title: String
        let tasks: [TaskSnapshot]
        let emptyTitle: String
        switch drawer {
        case .day:
            title = AppStyle.dayLabel(day) + " · " + AppStyle.weekdayLabel(day)
            tasks = model.scheduled(on: day)
            emptyTitle = "这一天没有安排"
        case .week(let list):
            title = list.title
            tasks = list.tasks(from: model.active, weekStart: monday, timeZone: .current)
            emptyTitle = list == .pending ? "这一周没有待安排任务" : "此前各周没有未完成任务"
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if !tasks.isEmpty {
                    Text("\(tasks.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { calendarDrawer = nil } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("收起清单").accessibilityLabel("收起清单")
                    .accessibilityIdentifier(drawer == .day ? "closeDayTasks" : "closeWeekTasks")
                    .keyboardShortcut(macSearchExpanded ? nil : .cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            WorkspaceScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(emptyTitle).foregroundStyle(.secondary)
                            calendarAgendaAddAction(drawer, day: day)
                        }.padding(.vertical, 18)
                    }
                    ForEach(tasks) { task in
                        if drawer == .day {
                            TaskAgendaRow(task: task, complete: { model.toggleCompletion(task) }) { model.selection = task.id }
                        } else {
                            macTaskRow(task, today: Day(date: Date(), timeZone: .current), showSchedule: drawer == .week(.previousWeeks))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            if !tasks.isEmpty && drawer != .week(.previousWeeks) {
                Divider()
                calendarAgendaAddAction(drawer, day: day).padding(16)
            }
        }
        .accessibilityIdentifier(drawer == .day ? "dayTasks-\(day.rawValue)" : "weekTasks-\(monday.rawValue)")
    }

    @ViewBuilder
    private func calendarAgendaAddAction(_ drawer: CalendarDrawer, day: Day) -> some View {
        if drawer != .week(.previousWeeks) {
            Button(drawer == .day ? "添加任务" : "加入本周", systemImage: "plus") {
                if drawer == .day { beginCapture(day: day) }
                else { presentCapture(schedule: .week(start: day.weekStart ?? day)) }
            }.buttonStyle(.borderless)
                .accessibilityIdentifier(drawer == .day ? "addDayTask" : "addToWeek")
        }
    }

    private var macSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: destinationSelection) {
                ForEach([Destination.today, .calendar, .todo], id: \.self) { item in
                    macSidebarRow(item)
                }
                Section {
                    ForEach([Destination.completed, .trash], id: \.self) { item in
                        macSidebarRow(item)
                    }
                } header: {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        .selectionDisabled()
                        .accessibilityHidden(true)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListHeaderHeight, 12)
            .padding(.vertical, 6)
            Divider().padding(.horizontal, 14)
            Button { showingInfo = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("设置").foregroundStyle(.primary)
                        Text("本机存储")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("openSettings")
        }
    }

    private func macSidebarRow(_ item: Destination) -> some View {
        Label {
            Text(item.rawValue)
                .font(.system(size: 15))
                .fontWeight(.regular)
        } icon: {
            let icon = Image(systemName: item.symbol)
                .font(.system(size: 17))
                .imageScale(.medium)
                .frame(width: 24)
            if item.acceptsNewTasks || destination == item {
                icon
            } else {
                icon.foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .tag(item)
        .accessibilityIdentifier("nav-\(item)")
    }

    @ToolbarContentBuilder
    private func macToolbar(windowWidth: CGFloat) -> some ToolbarContent {
        let showCalendar = model.loaded && destination == .calendar && query.isEmpty
        ToolbarItem(placement: .navigation) {
            if showCalendar && (!macSearchExpanded || windowWidth >= 840) {
                macCalendarDateControls
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            if showCalendar && section == .week && !macSearchExpanded { macWeekPendingButton }
        }
        ToolbarItem(placement: .primaryAction) { macSearchControl }
    }

    @ViewBuilder
    private var macSearchControl: some View {
        if macSearchExpanded {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(searchPrompt, text: $search)
                    .textFieldStyle(.plain)
                    .focused($macSearchFocused)
                    .accessibilityIdentifier("macSearchField")
                Button("结束搜索", systemImage: "xmark.circle.fill", action: endMacSearch)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("结束搜索")
            }
            .padding(.horizontal, 8)
            .frame(width: 216, height: 30)
            .onExitCommand(perform: endMacSearch)
            .task {
                await Task.yield()
                macSearchFocused = true
            }
        } else {
            Button("搜索任务", systemImage: "magnifyingglass") {
                if captureInThisWindow && !closeCaptureDrawer() { return }
                macSearchExpanded = true
            }
            .labelStyle(.iconOnly)
            .help("搜索任务")
            .keyboardShortcut(model.selected == nil && !captureInThisWindow ? KeyboardShortcut("f") : nil)
            .accessibilityIdentifier("openMacSearch")
        }
    }

    private func endMacSearch() {
        macSearchFocused = false
        macSearchExpanded = false
        search = ""
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
                plannerContent.frame(maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    macTaskCollection(today: Day(date: context.date, timeZone: .current))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { unreadableNotice }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.loaded && query.isEmpty && (destination == .today || destination == .todo) { quickEntry }
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
            if calendarDrawer == .week(.pending) { return .week(start: calendarDay.weekStart ?? calendarDay) }
            if calendarDrawer == .week(.previousWeeks) { return .none }
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
                HStack(spacing: 8) {
                    Text(captureSession.plan.schedule == .none ? "添加为未安排" : "添加到" + AppStyle.scheduleLabel(captureSession.plan.schedule))
                        .foregroundStyle(.secondary)
                    if captureSession.dateFromTitle {
                        Button("不按标题安排") { captureSession.ignoreTitleDate() }
                            .buttonStyle(.borderless)
                            .help("标题保持原样，按当前页面的默认安排添加")
                            .accessibilityIdentifier("ignoreTitleDate")
                    }
                }
                .font(.caption).padding(.leading, 16)
                .accessibilityIdentifier("quickEntryPlan")
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

    private func macTaskCollection(today: Day) -> some View {
        let tasks = collection(in: destination, matching: query)
        return WorkspaceScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(query.isEmpty ? destination.rawValue : "搜索结果").font(.system(size: 26, weight: .semibold))
                        Spacer()
                        if query.isEmpty && destination == .todo {
                            MacReminderImportEntry(reminders: model.reminders) { showingReminderImport = true }
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
                } else if destination == .todo && query.isEmpty && !tasks.isEmpty {
                    ForEach(TodoSections(tasks, on: today, timeZone: .current).groups) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            todoSectionHeader(section.group, count: section.items.count)
                            LazyVStack(spacing: 0) {
                                ForEach(section.items) { task in macTaskRow(task, today: today) }
                            }
                        }.accessibilityIdentifier("todoSection-\(section.group)")
                    }
                } else if tasks.isEmpty {
                    macCollectionEmpty
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(tasks) { task in macTaskRow(task, today: today) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.background(AppStyle.canvas(colorScheme))
            .accessibilityIdentifier(query.isEmpty ? "collection-\(destination)" : "searchResults")
    }

    private var macCollectionEmpty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(collectionEmptyTitle(in: destination, matching: query)).font(.title3.weight(.medium))
            if !query.isEmpty {
                Text("试试更短的标题关键词。").foregroundStyle(.secondary)
            } else if destination == .todo {
                Text("在下方记下一件事，回车即可添加。").font(.callout).foregroundStyle(.secondary)
            }
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
            Button { model.selection = task.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .strikethrough(task.isCompleted).fixedSize(horizontal: false, vertical: true)
                    if showSchedule || showsCollectionSchedule(for: task) {
                        Text(rowScheduleLabel(for: task)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = task.currentNote?.body, !note.isEmpty {
                        Text(note.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if task.heads.count > 1 {
                        Label("\(task.heads.count) 个正文分支", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开任务：\(task.title)").accessibilityValue(rowScheduleLabel(for: task))
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

    private func beginContextCapture() {
        endMacSearch()
        presentCapture(schedule: contextCaptureSchedule)
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

    @ViewBuilder
    private func todaySections(on today: Day) -> some View {
        let overview = TodayTasks(model.active, on: today, timeZone: .current)
        if overview.scheduled.isEmpty && overview.earlier.isEmpty {
            Text(overview.finishedToday.isEmpty ? "今天还没有安排" : "今天的任务都完成了")
                .foregroundStyle(.secondary)
        }
        ForEach(overview.scheduled) { todayRow($0, on: today) }
        if !overview.earlier.isEmpty {
            DisclosureGroup("此前未完成 · \(overview.earlier.count)", isExpanded: $earlierExpanded) {
                LazyVStack(spacing: 2) {
                    ForEach(overview.earlier) { todayRow($0, on: today, earlier: true) }
                }
            }.accessibilityIdentifier("earlierTasks")
        }
    }

    @ViewBuilder
    private var unreadableNotice: some View {
        if model.loaded && model.unreadableTasks > 0 {
            Label("有 \(model.unreadableTasks) 条任务暂时无法读取，已从列表中略过；原记录仍保留在任务库中。",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 8)
                .background(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.08))
                .accessibilityIdentifier("unreadableTasks")
        }
    }

    private func todoSectionHeader(_ group: TodoSections<TaskSnapshot>.Group, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(group.title).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.leading, 6).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func todayRow(_ task: TaskSnapshot, on today: Day, earlier: Bool = false) -> some View {
        macTaskRow(task, today: today, showSchedule: earlier)
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
            Button("设为未安排") { model.perform { try $0.scheduleTask(id: task.id, schedule: .none) } }
        }
    }

    @ViewBuilder
    private var plannerContent: some View {
        switch section {
        case .week:
            WeekView(model: model, selectedDay: $calendarDay, create: { beginCapture(day: $0) },
                     inspectDay: { _ in calendarDrawer = .day })
        case .month:
            MonthView(model: model, selectedDay: $calendarDay, create: { beginCapture(day: $0) },
                      inspectDay: { _ in calendarDrawer = .day })
        }
    }

    private func beginCapture(day: Day? = nil) {
        presentCapture(schedule: day.map { .allDay(start: $0, endExclusive: $0.addingIfPossible(days: 1) ?? $0) } ?? .none)
    }

    private func presentCapture(schedule: TaskSchedule) {
        TaskWritingEditor.finishEditing()
        quickEntryFocused = false
        captureSession.begin(schedule: schedule)
        dismissWindow(id: "capture")
        model.selection = nil
        captureSession.mainWindowID = mainWindowID
    }

    private func openURL(_ url: URL) {
        guard let destination = AppDestination(url: url) else { return }
        showingInfo = false
        switch destination {
        case .today:
            earlierExpanded = true
            navigate(.today)
        case .todo:
            navigate(.todo)
        case .task(let id):
            navigate(.todo)
            model.openTask(id: id)
        case .calendar(let day, let view):
            openCalendar(day: day, view: view)
        case .weekList(let monday, let list):
            openCalendar(day: monday, view: .week)
            calendarDrawer = .week(list)
        case .capture(let schedule):
            presentCapture(schedule: schedule)
        }
    }

    private func openCalendar(day: Day, view: CalendarPresentation) {
        calendarDay = day
        section = view == .month ? .month : .week
        navigate(.calendar)
        calendarDrawer = view == .week ? nil : .day
    }

}
