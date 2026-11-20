import Combine
import Foundation
import WidgetKit
import EventKit

@MainActor
final class AppModel: ObservableObject {
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
    private let localChanges = PassthroughSubject<Void, Never>()
    private var localReminderChanges: AnyCancellable?
    private var lastReminderDigest: Int?

    init() {
        localReminderChanges = localChanges
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in
                Task { @MainActor in
                    guard let self, self.reminders.autoSync else { return }
                    await self.reminders.refreshIfConnected()
                }
            }
        reminderChanges = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.reminders.refreshIfConnected() }
            }
    }
    private(set) var store: TaskStore?
    private var taskToOpen: UUID?
    private var waitingToOpenNoticeShown = false

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
        lastReminderDigest = nil
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
            let opened = try TaskStore(directory: directory, session: StoreSession.isLocalBuild ? nil : session)
            opened.onChange = { [weak self] in self?.reload() }
            opened.onHistoryReadFailure = { [weak self] in self?.status = "本机历史读取失败；本机数据保留" }
            store = opened
            storePath = directory.path
            if !StoreSession.isLocalBuild { try StoreSession.publish(session) }
            try opened.consumeHistory()
            if StoreSession.isMacDistributionBuild {
                // Some unreadable tasks still open the library; none readable at all suggests an
                // incompatible or damaged library, so startup fails and extensions stay blocked.
                let first = try opened.readableSnapshots()
                if first.tasks.isEmpty && first.unreadableCount > 0 {
                    throw AppError.unavailable("任务库中的任务都无法读取，可能来自更新的版本或已经损坏；没有写入。")
                }
            }
            reload()
            if selection == nil, previousPath == storePath,
               let previousSelection, tasks.contains(where: { $0.id == previousSelection }) {
                selection = previousSelection
            }
            status = StoreSession.isLocalBuild ? "独立本地测试库" : "本机任务库"
            loaded = true
            capture.attach(to: opened, tasks: tasks, skipping: unreadableIDs)
            reminders.attach(opened)
            Task { await reminders.refreshIfConnected() }
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
            var digest = Hasher()
            for task in tasks {
                digest.combine(task.id)
                digest.combine(task.title)
                digest.combine(task.isCompleted)
                digest.combine(task.deletedAt != nil)
                switch task.schedule {
                case .none: digest.combine(0)
                case let .week(start): digest.combine(1); digest.combine(start)
                case let .allDay(start, end): digest.combine(2); digest.combine(start); digest.combine(end)
                case let .timed(start, end, zone):
                    digest.combine(3); digest.combine(start); digest.combine(end); digest.combine(zone)
                }
            }
            let nextDigest = digest.finalize()
            if lastReminderDigest != nextDigest {
                lastReminderDigest = nextDigest
                localChanges.send()
            }
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
            guard let store, loaded else { throw AppError.unavailable("存储尚未就绪，请稍后重试。") }
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
}
