import CloudKit
import Combine
import Foundation
import WidgetKit
#if os(macOS)
import EventKit
#endif

@MainActor
final class PrototypeModel: ObservableObject {
    @Published var tasks: [TaskSnapshot] = []
    @Published var status = "正在打开隔离测试库…"
    @Published var error: String?
    @Published var selection: UUID?
    @Published var storePath = ""
    @Published var loaded = false
    @Published private(set) var cloudSyncEnabled = StoreSession.supportsCloudSync
        && UserDefaults.standard.bool(forKey: "M0CloudSyncEnabled")
    @Published private(set) var checkingAccount = false
    @Published private(set) var cloudAccountIssue: String?
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()
    @Published private(set) var session: StoreSession?
    struct CompletionFeedback: Identifiable {
        let id = UUID()
        let taskID: UUID
        let title: String
        let previousValue: Bool
        let storePath: String
    }
    @Published var completionFeedback: CompletionFeedback?
    let capture = CaptureDraft()
    #if os(macOS)
    let reminders = MacReminders()
    private var reminderChanges: AnyCancellable?

    init() {
        reminderChanges = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.reminders.refreshIfConnected() }
            }
    }
    #endif
    private(set) var store: TaskStore?
    private var accountObserver: NSObjectProtocol?
    private var starting = false
    private var restartRequested = false
    private var taskToOpen: UUID?
    private var accountCheckID = UUID()
    private var startedDistributionDirectory: URL?

    var selected: TaskSnapshot? { tasks.first { $0.id == selection } }
    var active: [TaskSnapshot] { tasks.filter { $0.deletedAt == nil } }

    var cloudAccountTitle: String {
        if !StoreSession.supportsCloudSync { return "此版本使用本机存储" }
        if !cloudSyncEnabled { return "未开启 iCloud 同步" }
        if checkingAccount { return "正在检查 Apple 账户…" }
        if cloudAccountIssue != nil { return "iCloud 暂不可用" }
        if !loaded { return "任务库尚未就绪" }
        return session?.cloudEnabled == true ? "使用系统 Apple 账户" : "尚未登录 iCloud"
    }

    func setCloudSyncEnabled(_ enabled: Bool) async {
        guard StoreSession.supportsCloudSync, enabled != cloudSyncEnabled else { return }
        cloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "M0CloudSyncEnabled")
        await start()
    }

    // Checking a healthy, unchanged account must not recreate its mirror or
    // clear its event history. Account notifications take the blocking path.
    func checkAccountAndStorage() async {
        guard !starting, !checkingAccount else { return }
        guard loaded, let session else { await start(); return }
        guard StoreSession.supportsCloudSync, cloudSyncEnabled else { reload(); return }
        let checkID = UUID()
        accountCheckID = checkID
        checkingAccount = true
        defer { if accountCheckID == checkID { checkingAccount = false } }
        do {
            let account = try await StoreSession.confirmedAccount()
            guard accountCheckID == checkID else { return }
            let confirmed = try StoreSession.cloudSession(syncEnabled: true, accountHash: account)
            if confirmed == session {
                try store?.consumeHistory()
                reload()
            } else { await start(confirmedAccount: .success(account)) }
        } catch {
            guard accountCheckID == checkID else { return }
            // Close the unconfirmed cloud library before falling back locally.
            await start(confirmedAccount: .failure(error))
        }
    }

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

    func start(confirmedAccount: Result<String?, Error>? = nil) async {
        guard !starting else { restartRequested = true; return }
        let previousPath = storePath
        let previousSelection = selection
        starting = true
        accountCheckID = UUID()
        checkingAccount = true
        capture.detach()
        #if os(macOS)
        reminders.attach(nil)
        #endif
        defer {
            starting = false
            checkingAccount = false
            if restartRequested {
                restartRequested = false
                Task { await start() }
            }
        }
        completionFeedback = nil
        loaded = false
        tasks = []
        selection = nil
        storePath = ""
        session = nil
        cloudAccountIssue = nil
        cloudSyncStatus = CloudSyncStatus()
        status = "正在检查账户与存储…"
        if accountObserver == nil && !StoreSession.isLocalBuild && !StoreSession.isDesktopLocalBuild {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged,
                                                                     object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.start() }
            }
        }
        do {
            let blockedSession = StoreSession.isLocalBuild ? nil : try StoreSession.blockExtensions()
            try store?.close()
            store = nil
            let session: StoreSession
            do {
                if StoreSession.supportsCloudSync, cloudSyncEnabled, let confirmedAccount {
                    session = try StoreSession.cloudSession(syncEnabled: true, accountHash: confirmedAccount.get())
                } else {
                    session = try await StoreSession.forMainApp(blockedSession: blockedSession, cloudSyncEnabled: cloudSyncEnabled)
                }
                status = session.cloudEnabled ? "已本机保存；iCloud 由系统异步交换"
                    : StoreSession.supportsCloudSync ? (cloudSyncEnabled ? "请在系统设置中登录 iCloud；当前使用本机收集箱" : "本机收集箱 · iCloud 同步已关闭")
                    : StoreSession.isDesktopLocalBuild ? "桌面本机任务 · 未接入 iCloud" : "独立本地测试库 · 未接入 iCloud"
            } catch {
                if StoreSession.isDesktopLocalBuild { throw error }
                session = StoreSession(modelVersion: StoreSession.modelVersion, namespace: "local-inbox",
                                       accountHash: nil, cloudEnabled: false, ready: false)
                cloudAccountIssue = error.localizedDescription
                status = "iCloud 身份待确认 · 使用独立本地收集箱"
            }
            guard !restartRequested else { return }
            let directory = try session.directory()
            #if os(macOS)
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
            #endif
            let opened = try TaskStore(directory: directory, cloudID: session.cloudEnabled ? StoreSession.cloudID : nil,
                                       session: StoreSession.isLocalBuild ? nil : session)
            opened.onChange = { [weak self] in self?.reload() }
            opened.onSyncEvent = { [weak self, weak opened] text in
                guard let self, let opened, self.store === opened else { return }
                self.cloudSyncStatus = opened.syncStatus
                self.status = text
            }
            store = opened
            self.session = session
            cloudSyncStatus = opened.syncStatus
            if session.cloudEnabled { status = cloudSyncStatus.summary }
            storePath = directory.path
            if !StoreSession.isLocalBuild { try StoreSession.publish(session) }
            try opened.consumeHistory()
            // reload() presents read errors without throwing. Confirm the first
            // distribution read before remembering a successful startup.
            if StoreSession.isMacDistributionBuild { _ = try opened.snapshots() }
            reload()
            if selection == nil, previousPath == storePath,
               let previousSelection, tasks.contains(where: { $0.id == previousSelection }) {
                selection = previousSelection
            }
            loaded = true
            capture.attach(to: opened, tasks: tasks)
            #if os(macOS)
            reminders.attach(opened)
            Task { await reminders.refreshIfConnected() }
            #endif
            if StoreSession.isMacDistributionBuild { startedDistributionDirectory = directory }
        } catch {
            try? store?.close()
            store = nil
            tasks = []
            selection = nil
            storePath = ""
            self.session = nil
            if !StoreSession.isLocalBuild { try? StoreSession.blockExtensions() }
            self.error = "存储未打开：\(error.localizedDescription) 原库已保留。"
            status = "启动失败 · 没有删库重建"
        }
    }

    func openTask(id: UUID) {
        taskToOpen = id
        if loaded { reload() }
    }

    func reload() {
        do {
            guard let store else { return }
            tasks = try store.snapshots()
            if let id = taskToOpen {
                taskToOpen = nil
                if tasks.contains(where: { $0.id == id }) { selection = id }
                else {
                    selection = nil
                    error = "此任务尚未出现在当前测试库。请确认账户，等待同步后重试。"
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            tasks = []
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
