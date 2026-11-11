#if os(macOS)
import SwiftUI
import WidgetKit

struct WidgetGalleryView: View {
    @ObservedObject var model: PrototypeModel
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode = CalendarWidgetMode.today
    @State private var family = WidgetFamily.systemMedium

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("桌面小组件").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("内容", selection: $mode) {
                    Text("今天").tag(CalendarWidgetMode.today)
                    Text("本周计划").tag(CalendarWidgetMode.week)
                    Text("月历总览").tag(CalendarWidgetMode.month)
                }.pickerStyle(.segmented).frame(width: 230)
                Spacer()
                Picker("尺寸", selection: $family) {
                    if mode == .today { Text("小号").tag(WidgetFamily.systemSmall) }
                    if mode != .month { Text("中号").tag(WidgetFamily.systemMedium) }
                    if mode != .today {
                        Text("大号").tag(WidgetFamily.systemLarge)
                        Text("宽版").tag(WidgetFamily.systemExtraLarge)
                    }
                }.pickerStyle(.segmented).frame(width: 190)
            }
            WidgetCalendarView(date: Date(), tasks: model.active.map {
                CalendarTask(id: $0.id, title: $0.title, schedule: $0.schedule, isCompleted: $0.isCompleted, preview: $0.currentNote?.body ?? "")
            }, mode: mode, family: family, complete: { id in
                model.perform { try $0.setCompleted(id: id, completed: true) }
            })
            .frame(width: family == .systemSmall ? 164 : family == .systemExtraLarge ? 704 : 344,
                   height: family == .systemMedium || family == .systemSmall ? 164 : 344)
            .background(AppStyle.surface(colorScheme), in: RoundedRectangle(cornerRadius: 20))
            .environment(\.openURL, OpenURLAction { url in open(url); return .handled })
            .frame(maxWidth: .infinity)
            Text("在桌面上右键，选择「编辑小组件」，搜索 Let’s Do 即可添加。").font(.callout).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 768)
        .background(AppStyle.canvas(colorScheme))
        .tint(AppStyle.accentText(colorScheme))
        .onChange(of: mode) { _, value in
            switch value {
            case .today: if family != .systemSmall { family = .systemMedium }
            case .week: if family == .systemSmall { family = .systemMedium }
            case .month: if family != .systemExtraLarge { family = .systemLarge }
            }
        }
    }
}
#endif
