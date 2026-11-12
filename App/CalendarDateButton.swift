import SwiftUI

struct CalendarDateButton: View {
    @Binding var day: Day
    let title: String
    var minimumHeight: CGFloat = 44
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(minHeight: minimumHeight, alignment: .leading)
        }
        .buttonStyle(.plain).accessibilityLabel(title + "，选择日期")
        .accessibilityIdentifier("chooseCalendarDate")
        .popover(isPresented: $showingPicker) {
            VStack(spacing: 8) {
                CompactDateCalendar(selection: Binding(get: { day }, set: {
                    day = $0; showingPicker = false
                }), accessibilityIdentifier: "calendarDateCalendar", allowsDay: {
                    // Both calendar views project complete months, including surrounding weeks.
                    let month = String($0.rawValue.prefix(7))
                    return month > "0001-01" && month < "9999-12"
                })
                Divider()
                HStack {
                    Button("今天") {
                        day = Day(date: Date(), timeZone: .current)
                        showingPicker = false
                    }
                    Spacer()
                }
                .frame(minHeight: 36)
            }
            .padding(8)
            #if os(macOS)
            .frame(width: 272)
            #else
            .frame(width: 336)
            #endif
            .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}

#if os(macOS)
struct MacCalendarNavigation: View {
    @Binding var selectedDay: Day
    let isWeek: Bool
    let shift: (Int) -> Void
    @State private var hoveredDirection: Int?

    var body: some View {
        let today = Day(date: .now, timeZone: .current)
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                arrow(-1, label: isWeek ? "上一周" : "上个月", identifier: isWeek ? "previousWeek" : "previousMonth")
                Divider().frame(height: 14).accessibilityHidden(true)
                arrow(1, label: isWeek ? "下一周" : "下个月", identifier: isWeek ? "nextWeek" : "nextMonth")
            }
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            if selectedDay != today {
                Button("回到今天") { selectedDay = today }
                    .help("回到今天的日期")
                    .accessibilityIdentifier(isWeek ? "todayWeek" : "todayMonth")
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func arrow(_ direction: Int, label: String, identifier: String) -> some View {
        Button { shift(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 28)
                .background(Color.primary.opacity(hoveredDirection == direction ? 0.09 : 0),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredDirection = direction }
            else if hoveredDirection == direction { hoveredDirection = nil }
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The free area in a day is an actionable target even when its affordance is quiet.
struct MacCalendarDayBackground: View {
    let day: Day
    let fill: Color
    let identifier: String
    let hover: (Bool) -> Void
    let create: () -> Void

    static func highlight(in colorScheme: ColorScheme) -> Color {
        AppStyle.accent.opacity(colorScheme == .dark ? 0.17 : 0.085)
    }

    var body: some View {
        Button(action: create) {
            Rectangle().fill(fill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .help("在\(AppStyle.dayLabel(day))添加任务")
        .accessibilityLabel("在\(AppStyle.dayLabel(day))添加任务")
        .accessibilityIdentifier(identifier)
    }
}
#endif
