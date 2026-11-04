import SwiftUI

/// Editing dates must not rewrite a legacy timed task until its dates actually change.
struct ScheduleForm: Equatable {
    enum Placement: String, CaseIterable {
        case none = "不安排", day = "某一天", week = "某一周"
    }
    var enabled = false
    var weekly = false
    var spansDays = false
    var start: Date
    var end: Date
    private let originalSchedule: TaskSchedule
    private let initialStart: Date
    private let initialEnd: Date
    private let initiallySpansDays: Bool

    init(schedule: TaskSchedule = .none) {
        originalSchedule = schedule
        let today = Day(date: Date(), timeZone: .current).date(in: .current)
        var first = today, last = today
        switch schedule {
        case .none: break
        case .week(let day): enabled = true; weekly = true; first = day.date(in: .current); last = first
        case .allDay, .timed:
            enabled = true
            if let days = schedule.dayRange(in: .current) {
                first = days.lowerBound.date(in: .current)
                last = days.upperBound.adding(days: -1).date(in: .current)
            }
        }
        start = first; end = last
        spansDays = last > first
        initialStart = first; initialEnd = last; initiallySpansDays = spansDays
    }

    var placement: Placement {
        get { !enabled ? .none : weekly ? .week : .day }
        set { enabled = newValue != .none; weekly = newValue == .week }
    }

    var retainsExistingTime: Bool {
        guard case .timed = originalSchedule else { return false }
        return enabled && !weekly && start == initialStart && end == initialEnd && spansDays == initiallySpansDays
    }

    var schedule: TaskSchedule {
        guard enabled else { return .none }
        let first = Day(date: start, timeZone: .current)
        if weekly { return .week(start: first.weekStart ?? first) }
        if retainsExistingTime { return originalSchedule }
        let last = spansDays ? Day(date: end, timeZone: .current) : first
        return .allDay(start: first, endExclusive: last.addingIfPossible(days: 1) ?? last)
    }

    var error: String? {
        guard enabled else { return nil }
        if !weekly && spansDays && end < start { return "结束日期不能早于开始日期。" }
        return (try? schedule.validated()) == nil ? "请检查安排的日期。" : nil
    }
}

struct ScheduleFields: View {
    @Binding var form: ScheduleForm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("安排到", selection: $form.placement) {
                ForEach(ScheduleForm.Placement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("schedulePlacement")
            if form.enabled {
                DatePicker(form.weekly ? "所在周" : "日期", selection: Binding(get: { form.start }, set: {
                    form.start = $0
                    if !form.spansDays { form.end = $0 }
                }), in: dateRange, displayedComponents: [.date])
                    .accessibilityIdentifier("scheduleStart")
                if !form.weekly {
                    Toggle("跨多天", isOn: $form.spansDays).accessibilityIdentifier("scheduleMultipleDays")
                    if form.spansDays {
                        DatePicker("至", selection: $form.end, in: dateRange, displayedComponents: [.date])
                            .accessibilityIdentifier("scheduleEnd")
                    }
                }
                if form.retainsExistingTime {
                    Text("保留原有时段；更改日期后改为按天安排。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = form.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("scheduleValidation")
                }
            }
        }
        .onChange(of: form.spansDays) { _, multiple in
            if multiple && form.end < form.start { form.end = form.start }
        }
    }

    private var dateRange: ClosedRange<Date> {
        try! Day("0001-01-01").date(in: .current)...Day("9999-12-30").date(in: .current)
    }
}

/// A small, shared month grid for date-only interactions. It intentionally
/// uses `Day` rather than a system `DatePicker`, so the same surface can be
/// embedded in a popover without opening a second calendar control.
struct CompactDateCalendar: View {
    @Binding var selection: Day
    let accessibilityIdentifier: String
    private let allowsDay: (Day) -> Bool

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedDay: Day?
    @State private var displayedMonth: Day

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private var daySize: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }

    init(selection: Binding<Day>, accessibilityIdentifier: String = "compactDateCalendar",
         allowsDay: @escaping (Day) -> Bool = { $0.addingIfPossible(days: 1) != nil }) {
        _selection = selection
        self.accessibilityIdentifier = accessibilityIdentifier
        self.allowsDay = allowsDay
        _displayedMonth = State(initialValue: Self.monthStart(of: selection.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                monthButton(offset: -1, symbol: "chevron.left", label: "上个月")
                Text(AppStyle.monthLabel(displayedMonth))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                monthButton(offset: 1, symbol: "chevron.right", label: "下个月")
            }

            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("星期一至星期日")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayButton(day)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: daySize, maxHeight: daySize)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .onAppear {
            displayedMonth = Self.monthStart(of: selection)
            focusedDay = selection
        }
        .onChange(of: selection) { _, value in
            displayedMonth = Self.monthStart(of: value)
        }
        #if os(macOS)
        .onMoveCommand { direction in moveFocus(direction) }
        #endif
    }

    private var gridDays: [Day?] {
        let first = Self.monthStart(of: displayedMonth)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let offset = (calendar.component(.weekday, from: first.date(in: .gmt)) + 5) % 7
        return (0..<42).map { first.addingIfPossible(days: $0 - offset) }
    }

    private func monthButton(offset: Int, symbol: String, label: String) -> some View {
        let target = Self.shiftMonth(displayedMonth, by: offset)
        let available = target.map(allowsDay) ?? false
        return Button {
            guard let target, available else { return }
            displayedMonth = target
            focusedDay = nil
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: daySize, height: daySize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .foregroundStyle(AppStyle.accentText(colorScheme).opacity(available ? 1 : 0.35))
        .accessibilityLabel(label)
        .accessibilityHint("切换显示月份")
        .accessibilityIdentifier("\(accessibilityIdentifier)-\(offset < 0 ? "previous" : "next")Month")
    }

    private func dayButton(_ day: Day) -> some View {
        let isSelected = day == selection
        let isToday = day == Day(date: Date(), timeZone: .current)
        let isCurrentMonth = Self.monthStart(of: day) == displayedMonth

        return Button {
            displayedMonth = Self.monthStart(of: day)
            selection = day
            focusedDay = day
        } label: {
            Text(String(Int(day.rawValue.suffix(2)) ?? 0))
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary))
                .frame(maxWidth: .infinity, minHeight: daySize, maxHeight: daySize)
                .background {
                    if isSelected {
                        Circle().fill(AppStyle.accent)
                    } else if isToday {
                        Circle().stroke(AppStyle.accent, lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focusedDay, equals: day)
        .disabled(!allowsDay(day))
        .accessibilityLabel(Self.longDateLabel(day))
        .accessibilityValue(isSelected ? "已选中" : (isToday ? "今天" : ""))
        .accessibilityIdentifier("\(accessibilityIdentifier)-\(day.rawValue)")
    }

    #if os(macOS)
    private func moveFocus(_ direction: MoveCommandDirection) {
        let current = focusedDay ?? selection
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -7
        case .down: delta = 7
        default: return
        }
        guard let next = current.addingIfPossible(days: delta) else { return }
        displayedMonth = Self.monthStart(of: next)
        focusedDay = next
    }
    #endif

    private static func monthStart(of day: Day) -> Day {
        let parts = day.rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let result = try? Day("\(parts[0])-\(padded(month, width: 2))-01") else {
            return day
        }
        return result
    }

    private static func shiftMonth(_ day: Day, by offset: Int) -> Day? {
        let parts = day.rawValue.split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        let index = year * 12 + month - 1 + offset
        guard (12..<120_000).contains(index) else { return nil }
        return try? Day("\(padded(index / 12, width: 4))-\(padded(index % 12 + 1, width: 2))-01")
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func longDateLabel(_ day: Day) -> String {
        let parts = day.rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let number = Int(parts[2]) else {
            return AppStyle.dayLabel(day)
        }
        return "\(parts[0])年\(month)月\(number)日，\(AppStyle.weekdayLabel(day))"
    }
}

/// A lightweight date editor for the detail popover.  The date draft stays
/// local until the user applies it; the host owns the task mutation and
/// dismissal.
struct TaskDatePopover: View {
    private enum Screen {
        case quick
        case calendar
    }

    private enum RangeTarget {
        case start
        case end
    }

    let schedule: TaskSchedule
    let apply: (TaskSchedule) -> Bool
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var screen: Screen = .quick
    @State private var form: ScheduleForm
    @State private var rangeTarget: RangeTarget = .start
    @State private var failureMessage: String?
    @State private var advancedDates: Bool

    init(schedule: TaskSchedule, apply: @escaping (TaskSchedule) -> Bool, close: @escaping () -> Void) {
        self.schedule = schedule
        self.apply = apply
        self.close = close

        let initial = ScheduleForm(schedule: schedule)
        _form = State(initialValue: initial)
        _advancedDates = State(initialValue: initial.weekly || initial.spansDays)
    }

    private var optionHeight: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch screen {
            case .quick:
                quickChoices
            case .calendar:
                calendarSelection
            }
        }
        .padding(8)
        #if os(macOS)
        .frame(width: 272)
        #else
        .frame(width: 336)
        #endif
        .tint(AppStyle.accentText(colorScheme))
        .onChange(of: form.placement) { _, value in
            failureMessage = nil
            if value == .week {
                form.spansDays = false
                rangeTarget = .start
            }
        }
        .onChange(of: form.spansDays) { _, multiple in
            failureMessage = nil
            if !multiple {
                rangeTarget = .start
                form.end = form.start
            } else if form.end < form.start {
                form.end = form.start
            }
        }
        #if os(macOS)
        .onExitCommand { close() }
        #endif
    }

    private var quickChoices: some View {
        let today = Day(date: Date(), timeZone: .current)
        let tomorrow = today.adding(days: 1)
        let nextWeek = (today.weekStart ?? today).adding(days: 7)

        return VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
            HStack {
                Spacer()
                closeButton
            }
            #endif

            VStack(spacing: 0) {
                quickChoice(title: "今天", detail: AppStyle.weekdayLabel(today), identifier: "scheduleToday") {
                    applyQuick(today)
                }
                quickChoice(title: "明天", detail: AppStyle.weekdayLabel(tomorrow), identifier: "scheduleTomorrow") {
                    applyQuick(tomorrow)
                }
                quickChoice(title: "下周一", detail: AppStyle.dayLabel(nextWeek), identifier: "scheduleNextWeek") {
                    applyQuick(nextWeek)
                }
            }
            .padding(.top, 2)

            Divider().padding(.vertical, 6)

            Button {
                screen = .calendar
                failureMessage = nil
                if form.placement == .none { form.placement = .day }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .foregroundStyle(AppStyle.accentText(colorScheme))
                    Text("选择日期…")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DateOptionButtonStyle())
            .accessibilityLabel("选择日期")
            .accessibilityIdentifier("scheduleChooseDate")

            if schedule != .none {
                Divider().padding(.top, 6)
                Button {
                    applySchedule(.none)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark").frame(width: 16)
                        Text("移除日期")
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DateOptionButtonStyle())
                .accessibilityIdentifier("scheduleRemoveDate")
            }

            failureView
        }
    }

    private var calendarSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { screen = .quick; failureMessage = nil } label: {
                    Label("选择日期", systemImage: "chevron.left")
                }.buttonStyle(.borderless).accessibilityIdentifier("datePickerBack")
                Spacer()
                #if os(iOS)
                closeButton
                #endif
            }
            CompactDateCalendar(selection: activeDay, accessibilityIdentifier: "scheduleDatePicker")
            Divider()
            DisclosureGroup("更多日期选项", isExpanded: $advancedDates) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("安排方式", selection: $form.placement) {
                        Text("按日期").tag(ScheduleForm.Placement.day)
                        Text("按周").tag(ScheduleForm.Placement.week)
                    }.pickerStyle(.segmented).accessibilityIdentifier("scheduleCalendarPlacement")
                    if form.placement == .day {
                        Toggle("跨多天", isOn: $form.spansDays)
                            .accessibilityIdentifier("scheduleMultipleDaysPopover")
                        if form.spansDays {
                            HStack(spacing: 8) {
                                rangeTargetButton(.start, title: "开始", date: form.start, identifier: "scheduleRangeStart")
                                rangeTargetButton(.end, title: "结束", date: form.end, identifier: "scheduleRangeEnd")
                            }
                        }
                    }
                    Text(selectionSummary).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.subheadline).accessibilityIdentifier("scheduleAdvancedDates")
            if form.retainsExistingTime {
                Text("保留原有时段；更改日期后改为按天安排。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = form.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("scheduleValidationPopover")
            }
            if advancedDates || form.weekly || form.spansDays || failureMessage != nil {
                HStack {
                    Spacer()
                    Button(failureMessage == nil ? "应用" : "重试") {
                        guard form.error == nil else { return }
                        applySchedule(form.schedule)
                    }.buttonStyle(.borderedProminent).tint(AppStyle.accent)
                        .disabled(form.error != nil || (form.schedule == schedule && failureMessage == nil))
                        .accessibilityIdentifier("scheduleApply")
                }
            }
            failureView
        }
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("scheduleClose")
        .keyboardShortcut(.cancelAction)
    }

    private func quickChoice(title: String, detail: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(AppStyle.accentText(colorScheme))
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DateOptionButtonStyle())
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityIdentifier(identifier)
    }

    private func rangeTargetButton(_ target: RangeTarget, title: String, date: Date, identifier: String) -> some View {
        let day = Day(date: date, timeZone: .current)
        return Button {
            rangeTarget = target
            failureMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(AppStyle.dayLabel(day))
                    .font(.subheadline.weight(rangeTarget == target ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(rangeTarget == target ? AppStyle.accentText(colorScheme) : .secondary)
        .accessibilityLabel("\(title)日期，\(AppStyle.dayLabel(day))")
        .accessibilityIdentifier(identifier)
    }

    private var activeDay: Binding<Day> {
        Binding(
            get: {
                let date = rangeTarget == .end && form.placement == .day && form.spansDays ? form.end : form.start
                return Day(date: date, timeZone: .current)
            },
            set: { value in selectCalendarDay(value) }
        )
    }

    private func selectCalendarDay(_ day: Day) {
        failureMessage = nil
        var next = form
        if next.placement == .day && next.spansDays && rangeTarget == .end {
            next.end = day.date(in: .current)
        } else {
            next.start = day.date(in: .current)
            if next.placement == .week || !next.spansDays { next.end = next.start }
        }
        form = next

        // A single date is a direct action. Ranges and weekly plans remain a
        // local draft until the explicit Apply button is pressed.
        if next.placement == .day && !next.spansDays && next.error == nil {
            applySchedule(next.schedule)
        }
    }

    private var selectionSummary: String {
        switch form.placement {
        case .none:
            return "不安排"
        case .week:
            let selected = Day(date: form.start, timeZone: .current)
            let first = selected.weekStart ?? selected
            return "\(AppStyle.dayLabel(first)) – \(AppStyle.dayLabel(first.addingIfPossible(days: 6) ?? first))"
        case .day:
            let first = Day(date: form.start, timeZone: .current)
            guard form.spansDays else { return "\(AppStyle.dayLabel(first))（\(AppStyle.weekdayLabel(first))）" }
            let last = Day(date: form.end, timeZone: .current)
            return "\(AppStyle.dayLabel(first)) – \(AppStyle.dayLabel(last))"
        }
    }

    private var failureView: some View {
        Group {
            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scheduleApplyFailure")
            }
        }
    }

    private func applyQuick(_ day: Day) {
        applySchedule(.allDay(start: day, endExclusive: day.adding(days: 1)))
    }

    private func applySchedule(_ value: TaskSchedule) {
        failureMessage = nil
        if apply(value) {
            close()
        } else {
            failureMessage = "日期未能保存，请重试。"
        }
    }
}

private struct DateOptionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(hovered || configuration.isPressed ? AppStyle.accentText(colorScheme).opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
