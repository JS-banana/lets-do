import SwiftUI

struct CalendarDateButton: View {
    @Binding var day: Day
    let title: String
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(minHeight: 44, alignment: .leading)
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
