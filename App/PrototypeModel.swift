import Combine
import Foundation
import WidgetKit
import EventKit

@MainActor
final class PrototypeModel: ObservableObject {
    @Published var tasks: [TaskSnapshot] = []
    /// Tasks left out of `tasks` because a record could not be read; their records stay untouched.
    @Published private(set) var unreadableTasks = 0
    private(set) var unreadableIDs: Set<UUID> = []
    @Published var status = "正在打开任务库…"
    @Published var error: String?
    @Published var selection: UUID?
    @Published var storePath = ""
    @Published var loaded = false
    struct CompletionFeedback: Identifiable {
        let id = UUID()
        let taskID: UUID
        let title: String
        let previousValue: Bool
        let storePath: String
    }
    @Published var completionFeedback: CompletionFeedback?
    let capture = CaptureDraft()
    let reminders = MacReminders()
    private var reminderChanges: AnyCancellable?

    init() {
        reminderChanges = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.reminders.refreshIfConnected() }
            }
    }
    private(set) var store: TaskStore?
    private var taskToOpen: UUID?
    private var waitingToOpenNoticeShown = false
    private var startedDistributionDirectory: URL?

    var selected: TaskSnapshot? { tasks.first { $0.id == selection } }
    var active: [TaskSnapshot] { tasks.filter { $0.deletedAt == nil } }

    func scheduled(on day: Day) -> [TaskSnapshot] {
        active.filter { $0.schedule.dayRange(in: .current)?.contains(day) == true }.sorted { lhs, rhs in
            switch (lhs.schedule, rhs.schedule) {
            case (.allDay, .timed): return true
            case (.timed, .allDay): return false
            case (.timed(let first, _, _), .timed(let second, _, _)):
                if first != second { return first < second }
            default: break
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func start() async {
        let previousPath = storePath
        let previousSelection = selection
        capture.detach()
        reminders.attach(nil)
        completionFeedback = nil
        loaded = false
        tasks = []
        unreadableTasks = 0
        unreadableIDs = []
        selection = nil
        storePath = ""
        status = "正在打开任务库…"
        do {
            let blockedSession = StoreSession.isLocalBuild ? nil : try StoreSession.blockExtensions()
            try store?.close()
            store = nil
            let session = try StoreSession.forMainApp(blockedSession: blockedSession)
            let directory = try session.directory()
            if StoreSession.isMacDistributionBuild {
                if let startedDistributionDirectory {
                    guard startedDistributionDirectory == directory else {
                        throw PrototypeError.unavailable("任务空间已切换，请退出并重新打开应用后检查新任务库；没有在运行中升级其他库。")
                    }
                } else {
                    // Upgrade only before a successful startup. Same-library
                    // restarts must not rely on detach() persisting a draft.
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: false)
                    let source = try session.legacyLocalDirectory(applicationSupport: support,
                                                                  arguments: ProcessInfo.processInfo.arguments)
                    try LocalLibraryUpgrade.prepare(source: source, target: directory)
                }
            }
            let opened = try TaskStore(directory: directory, session: StoreSession.isLocalBuild ? nil : session)
            opened.onChange = { [weak self] in self?.reload() }
            opened.onHistoryReadFailure = { [weak self] in self?.status = "本机历史读取失败；本机数据保留" }
            store = opened
            storePath = directory.path
            if !StoreSession.isLocalBuild { try StoreSession.publish(session) }
            try opened.consumeHistory()
            // reload() presents read errors without throwing. Confirm the first
            // distribution read before remembering a successful startup.
            if StoreSession.isMacDistributionBuild {
                // Some unreadable tasks still open the library; none readable at all suggests an
                // incompatible or damaged library, so startup fails and extensions stay blocked.
                let first = try opened.readableSnapshots()
                if first.tasks.isEmpty && first.unreadableCount > 0 {
                    throw PrototypeError.unavailable("任务库中的任务都无法读取，可能来自更新的版本或已经损坏；没有写入。")
                }
            }
            reload()
            if selection == nil, previousPath == storePath,
               let previousSelection, tasks.contains(where: { $0.id == previousSelection }) {
                selection = previousSelection
            }
            status = StoreSession.isLocalBuild ? "独立本地测试库" : "桌面本机任务"
            loaded = true
            capture.attach(to: opened, tasks: tasks, skipping: unreadableIDs)
            reminders.attach(opened)
            Task { await reminders.refreshIfConnected() }
            if StoreSession.isMacDistributionBuild { startedDistributionDirectory = directory }
        } catch {
            try? store?.close()
            store = nil
            tasks = []
            unreadableTasks = 0
            unreadableIDs = []
            selection = nil
            storePath = ""
            if !StoreSession.isLocalBuild { try? StoreSession.blockExtensions() }
            self.error = "存储未打开：\(error.localizedDescription) 原库已保留。"
            status = "启动失败 · 没有删库重建"
        }
    }

    func openTask(id: UUID) {
        taskToOpen = id
        waitingToOpenNoticeShown = false
        if loaded { reload() }
    }

    func reload() {
        do {
            guard let store else { return }
            let read = try store.readableSnapshots()
            tasks = read.tasks
            unreadableTasks = read.unreadableCount
            unreadableIDs = read.unreadableIDs
            if let id = taskToOpen {
                if tasks.contains(where: { $0.id == id }) {
                    taskToOpen = nil
                    selection = id
                } else if read.unreadableIDs.contains(id) {
                    // Keep the request; the task opens once its records can be read again.
                    if !waitingToOpenNoticeShown {
                        waitingToOpenNoticeShown = true
                        error = "这条任务暂时无法读取，原记录已保留；恢复后会自动打开。"
                    }
                } else {
                    taskToOpen = nil
                    selection = nil
                    error = "没有找到这条任务。请检查当前任务库。"
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            tasks = []
            unreadableTasks = 0
            unreadableIDs = []
            selection = nil
            self.error = error.localizedDescription
        }
    }

    // Success describes the action; snapshot read errors are reported separately by reload().
    @discardableResult
    func perform(_ action: (TaskStore) throws -> Void) -> Bool {
        do {
            guard let store, loaded else { throw PrototypeError.unavailable("存储尚未就绪，请稍后重试。") }
            // TaskStore synchronously publishes committed snapshots before returning.
            try action(store)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggleCompletion(_ task: TaskSnapshot) {
        guard perform({ try $0.setCompleted(id: task.id, completed: !task.isCompleted) }) else { return }
        completionFeedback = CompletionFeedback(taskID: task.id, title: task.title,
                                                previousValue: task.isCompleted, storePath: storePath)
    }

    func undoCompletion() {
        guard let feedback = completionFeedback, feedback.storePath == storePath,
              let task = tasks.first(where: { $0.id == feedback.taskID }), task.deletedAt == nil,
              task.isCompleted != feedback.previousValue else { completionFeedback = nil; return }
        if perform({ try $0.setCompleted(id: feedback.taskID, completed: feedback.previousValue) }) {
            completionFeedback = nil
        }
    }

    func create(title: String, id: UUID, schedule: TaskSchedule = .none,
                body: String = "", formatting: NoteFormatting? = nil) -> Bool {
        let saved = perform { try $0.createTask(id: id, title: title, schedule: schedule, body: body, formatting: formatting) }
        if saved { selection = id }
        return saved
    }

    func move(id: UUID, to day: Day) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        perform { store in
            let schedule: TaskSchedule = task.schedule == .none ? .allDay(start: day, endExclusive: day.adding(days: 1))
                : try task.schedule.moved(to: day, displayTimeZone: .current)
            try store.scheduleTask(id: id, schedule: schedule)
        }
    }

    func seed() {
        perform { store in
            let fixtures: [(String, String, String? , String?)] = [
                ("00000000-0000-0000-0000-000000000001", "M0 · 上月跨入", "2026-09-30", "2026-10-03"),
                ("00000000-0000-0000-0000-000000000002", "M0 · 跨周准备", "2026-10-17", "2026-10-22"),
                ("00000000-0000-0000-0000-000000000003", "M0 · 阅读方案", "2026-10-19", "2026-10-20"),
                ("00000000-0000-0000-0000-000000000004", "M0 · 本机重启检查", "2026-10-19", "2026-10-20"),
                ("00000000-0000-0000-0000-000000000005", "M0 · 小组件待验", "2026-10-19", "2026-10-20"),
                ("00000000-0000-0000-0000-000000000006", "M0 · 更多任务一", "2026-10-19", "2026-10-20"),
                ("00000000-0000-0000-0000-000000000007", "M0 · 更多任务二", "2026-10-19", "2026-10-20"),
                ("00000000-0000-0000-0000-000000000008", "M0 · 尚未安排", nil, nil),
                ("00000000-0000-0000-0000-000000000009", "M0 · 跨年连续", "2026-12-30", "2027-01-03")
            ]
            for (key, title, start, end) in fixtures {
                let id = UUID(uuidString: key)!
                guard !tasks.contains(where: { $0.id == id }) else { continue }
                try store.createTask(id: id, title: title)
                if let start, let end {
                    try store.scheduleTask(id: id, schedule: .allDay(start: Day(start), endExclusive: Day(end)))
                }
            }
            let midnightID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
            if !tasks.contains(where: { $0.id == midnightID }) {
                try store.createTask(id: midnightID, title: "M0 · 23:00 至零点")
                let zone = TimeZone(identifier: "Asia/Shanghai")!
                let start = try Day("2026-10-23").date(in: zone).addingTimeInterval(23 * 3_600)
                try store.scheduleTask(id: midnightID, schedule: .timed(start: start, end: start.addingTimeInterval(3_600), timeZoneID: zone.identifier))
            }
        }
    }
}
