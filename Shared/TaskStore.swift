import CloudKit
import CoreData
import Darwin
import Foundation
import OSLog

struct NoteRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let body: String
    let parentIDs: [UUID]
    let createdAt: Date
    var formatting: NoteFormatting? = nil

    static func validateGraph(_ revisions: [NoteRevision]) throws {
        let ids = Set(revisions.map(\.id))
        var dependencies = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, Set($0.parentIDs).intersection(ids)) })
        var children: [UUID: [UUID]] = [:]
        for revision in revisions { for parent in Set(revision.parentIDs).intersection(ids) { children[parent, default: []].append(revision.id) } }
        var ready = dependencies.filter { $0.value.isEmpty }.map(\.key)
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for child in children[id, default: []] {
                dependencies[child]?.remove(id)
                if dependencies[child]?.isEmpty == true { ready.append(child) }
            }
        }
        guard visited == revisions.count else { throw PrototypeError.invalid("正文父版本存在循环，未覆盖原记录。") }
    }
}

// Drafts are device-local recovery material, outside the mirrored Core Data model.
struct LocalDraft: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case capture, editor }
    let formatVersion: Int
    let id: UUID
    let taskID: UUID
    let kind: Kind
    let title: String
    let body: String
    let parentIDs: [UUID]
    let updatedAt: Date
    var captureSchedule: TaskSchedule? = nil
    var formatting: NoteFormatting? = nil
}

struct TaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let deletedAt: Date?
    let schedule: TaskSchedule
    let currentRevisionID: UUID?
    let revisions: [NoteRevision]

    var isCompleted: Bool { completedAt != nil }
    var currentNote: NoteRevision? {
        revisions.first { $0.id == currentRevisionID } ?? heads.first
    }
    var heads: [NoteRevision] {
        let parents = Set(revisions.flatMap(\.parentIDs))
        return revisions.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct TaskArchive: Codable, Sendable {
    let formatVersion: Int
    let modelVersion: Int
    let exportedAt: Date
    let tasks: [TaskSnapshot]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 20_000_000 else { throw PrototypeError.invalid("M0 备份超过 20 MB，未导入。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.formatVersion == 1, (1...StoreSession.modelVersion).contains(archive.modelVersion) else {
            throw PrototypeError.invalid("备份版本不受支持；原库未改动。")
        }
        guard Set(archive.tasks.map(\.id)).count == archive.tasks.count else {
            throw PrototypeError.invalid("备份存在重复任务 UUID；未导入。")
        }
        var revisionIDs = Set<UUID>()
        for task in archive.tasks {
            _ = try TaskStore.validTitle(task.title)
            _ = try task.schedule.validated()
            for revision in task.revisions {
                guard revision.taskID == task.id, revision.body.utf8.count <= 1_000_000,
                      !revision.parentIDs.contains(revision.id), revisionIDs.insert(revision.id).inserted else {
                    throw PrototypeError.invalid("正文版本内容或身份无效；未导入。")
                }
                _ = try revision.formatting?.validated(for: revision.body)
            }
            try NoteRevision.validateGraph(task.revisions)
        }
        return archive
    }
}

enum CloudSyncDirection: String, Equatable, Hashable, Sendable {
    case `import`
    case `export`
    case setup

    var label: String {
        switch self {
        case .import: "接收"
        case .export: "发送"
        case .setup: "连接"
        }
    }
}

enum CloudSyncFailure: String, Equatable, Sendable {
    case network
    case quota
    case account
    case permission
    case rateLimited
    case unknown

    init(error: Error) {
        var visited = Set<ObjectIdentifier>()
        self = Self.resolve(error, depth: 0, visited: &visited)
    }

    private static let maxUnwrapDepth = 8
    private static let maxPartialErrors = 32

    private static func resolve(_ error: Error, depth: Int,
                                visited: inout Set<ObjectIdentifier>) -> Self {
        guard depth < maxUnwrapDepth else { return .unknown }
        let nsError = error as NSError
        guard visited.insert(ObjectIdentifier(nsError)).inserted else { return .unknown }

        if nsError.domain == CKError.errorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            if code == .partialFailure {
                return resolvePartial(nsError, depth: depth, visited: &visited)
            }
            if let direct = directMapping(for: code) { return direct }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return resolve(underlying, depth: depth + 1, visited: &visited)
        }
        return .unknown
    }

    private static func resolvePartial(_ error: NSError, depth: Int,
                                       visited: inout Set<ObjectIdentifier>) -> Self {
        let raw = error.userInfo[CKPartialErrorsByItemIDKey]
        let values: [Any]
        if let dictionary = raw as? NSDictionary {
            values = Array(dictionary.allValues.prefix(maxPartialErrors))
        } else if let dictionary = raw as? [AnyHashable: Any] {
            values = Array(dictionary.values.prefix(maxPartialErrors))
        } else {
            values = []
        }

        var best: Self?
        for value in values {
            guard let nested = value as? Error else { continue }
            let candidate = resolve(nested, depth: depth + 1, visited: &visited)
            guard candidate != .unknown else { continue }
            if best == nil || candidate.priority > best!.priority { best = candidate }
        }
        return best ?? .unknown
    }

    private static func directMapping(for code: CKError.Code) -> Self? {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost, .zoneBusy:
            .network
        case .quotaExceeded:
            .quota
        case .notAuthenticated, .managedAccountRestricted, .accountTemporarilyUnavailable:
            .account
        case .permissionFailure, .missingEntitlement, .badContainer, .badDatabase:
            .permission
        case .requestRateLimited:
            .rateLimited
        default:
            nil
        }
    }

    private var priority: Int {
        switch self {
        case .quota: 5
        case .network: 4
        case .account: 3
        case .permission: 2
        case .rateLimited: 1
        case .unknown: 0
        }
    }

    var recoveryMessage: String {
        switch self {
        case .network:
            "网络暂不可用，请检查网络连接后重试。"
        case .quota:
            "iCloud 存储空间不足，请清理空间后重试。"
        case .account:
            "iCloud 账户不可用，请登录正确账户后重试。"
        case .permission:
            "没有 iCloud 数据权限，请检查账户与应用权限后重试。"
        case .rateLimited:
            "iCloud 请求过于频繁，请稍后重试。"
        case .unknown:
            "暂时无法完成同步，原有数据已保留，请稍后重试。"
        }
    }
}

struct CloudSyncEvent: Equatable, Sendable {
    let id: UUID
    let direction: CloudSyncDirection
    let startDate: Date
    let endDate: Date?
    let succeeded: Bool
    let failure: CloudSyncFailure?

    init(id: UUID, direction: CloudSyncDirection, startDate: Date,
         endDate: Date? = nil, succeeded: Bool = false, failure: CloudSyncFailure? = nil) {
        self.id = id
        self.direction = direction
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.failure = failure
    }
}

struct CloudSyncStatus: Equatable, Sendable {
    private struct FailureState: Equatable, Sendable {
        let occurredAt: Date
        let kind: CloudSyncFailure
    }

    private struct DirectionState: Equatable, Sendable {
        var lastSuccess: Date?
        var failure: FailureState?
    }

    private struct EventState: Equatable, Sendable {
        let direction: CloudSyncDirection
        var endDate: Date?
    }

    // Keep terminal UUID tombstones: evicting one would let a late start
    // notification for that event make the status busy again.
    private var events: [UUID: EventState] = [:]
    private var importState = DirectionState()
    private var exportState = DirectionState()
    private var setupState = DirectionState()

    init() {}

    var lastImport: Date? { importState.lastSuccess }
    var lastExport: Date? { exportState.lastSuccess }

    var failureMessage: String? {
        let failures: [(CloudSyncDirection, FailureState)] = [
            (.import, importState.failure),
            (.export, exportState.failure),
            (.setup, setupState.failure)
        ].compactMap { direction, state in
            state.map { (direction, $0) }
        }
        guard let latest = failures.max(by: { $0.1.occurredAt < $1.1.occurredAt }) else { return nil }
        return "iCloud \(latest.0.label)失败：\(latest.1.kind.recoveryMessage)"
    }

    var summary: String {
        let active = Set(events.values.compactMap { $0.endDate == nil ? $0.direction : nil })
            .sorted { $0.rawValue < $1.rawValue }
        if !active.isEmpty {
            let running = active == [.setup] ? "正在连接 iCloud"
                : "正在与 iCloud 交换数据（\(active.map(\.label).joined(separator: "、"))）"
            if let failureMessage { return "\(running)；\(failureMessage)" }
            return running
        }
        if let failureMessage { return failureMessage }

        let completed: [String] = [
            lastImport.map { _ in "接收" },
            lastExport.map { _ in "发送" }
        ].compactMap { $0 }
        if !completed.isEmpty {
            let exchange = completed.joined(separator: "和")
            return "本机已完成 iCloud \(exchange)；不代表另一台设备已收到"
        }
        if setupState.lastSuccess != nil { return "iCloud 已连接，尚未交换任务数据" }
        return "尚未同步"
    }

    mutating func apply(_ event: CloudSyncEvent) {
        let isFinished = event.endDate != nil
        if let previous = events[event.id] {
            // A terminal event is final for its UUID. This also drops a queued
            // start notification that arrives after close/reopen or after finish.
            if previous.endDate != nil {
                guard let previousEnd = previous.endDate, let incomingEnd = event.endDate,
                      incomingEnd > previousEnd else { return }
            }
        }

        let direction = events[event.id]?.direction ?? event.direction
        events[event.id] = EventState(direction: direction, endDate: event.endDate)
        if isFinished {
            let occurredAt = event.endDate ?? event.startDate
            if event.succeeded, event.failure == nil {
                applySuccess(direction, at: occurredAt)
            } else {
                applyFailure(direction, at: occurredAt, kind: event.failure ?? .unknown)
            }
        } else if let failure = event.failure {
            // Keep the event active until Core Data reports its end, but surface
            // an error immediately if CloudKit supplies one on a running update.
            applyFailure(direction, at: event.startDate, kind: failure)
        }
    }

    private mutating func applySuccess(_ direction: CloudSyncDirection, at date: Date) {
        switch direction {
        case .import:
            applySuccess(at: date, to: &importState)
        case .export:
            applySuccess(at: date, to: &exportState)
        case .setup:
            applySuccess(at: date, to: &setupState)
        }
    }

    private func applySuccess(at date: Date, to state: inout DirectionState) {
        if state.lastSuccess == nil || state.lastSuccess! < date { state.lastSuccess = date }
        if (state.failure?.occurredAt ?? .distantPast) <= date { state.failure = nil }
    }

    private mutating func applyFailure(_ direction: CloudSyncDirection, at date: Date,
                                       kind: CloudSyncFailure) {
        switch direction {
        case .import:
            applyFailure(at: date, kind: kind, to: &importState)
        case .export:
            applyFailure(at: date, kind: kind, to: &exportState)
        case .setup:
            applyFailure(at: date, kind: kind, to: &setupState)
        }
    }

    private func applyFailure(at date: Date, kind: CloudSyncFailure,
                              to state: inout DirectionState) {
        // An older callback must not overwrite a newer successful exchange.
        if let lastSuccess = state.lastSuccess, lastSuccess > date { return }
        if (state.failure?.occurredAt ?? .distantPast) <= date {
            state.failure = FailureState(occurredAt: date, kind: kind)
        }
    }
}

// Main-queue contexts stay here. Views and intents receive only value snapshots/UUIDs.
@MainActor
final class TaskStore {
    private(set) var container: NSPersistentContainer?
    let directory: URL
    let isExtension: Bool
    private let mirrored: Bool
    private let session: StoreSession?
    private var modelLease: StoreFileLock?
    private var observer: NSObjectProtocol?
    private var eventObserver: NSObjectProtocol?
    private var token: NSPersistentHistoryToken?
    private var callbackGeneration = UUID()
    var onChange: (() -> Void)?
    var onSyncEvent: ((String) -> Void)?
    private(set) var syncStatus: CloudSyncStatus = .init()
    private static var mirrorOwners = Set<URL>()
    private static let logger = Logger(subsystem: "com.panion.todo.m0", category: "store")

    private var context: NSManagedObjectContext {
        get throws {
            guard let container else { throw PrototypeError.unavailable("存储已关闭，请重新打开应用。") }
            return container.viewContext
        }
    }

    private func acceptsCallback(generation: UUID, containerID: ObjectIdentifier) -> Bool {
        guard callbackGeneration == generation, let container else { return false }
        return ObjectIdentifier(container) == containerID
    }

    nonisolated static func validTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192 else {
            throw PrototypeError.invalid("请输入标题（最多 8 KB）。")
        }
        return value
    }

    init(directory: URL, cloudID: String? = nil, isExtension: Bool = false, session: StoreSession? = nil) throws {
        self.directory = directory
        self.isExtension = isExtension
        self.session = session
        mirrored = cloudID != nil
        guard !(isExtension && mirrored) else {
            throw PrototypeError.invalid("扩展不能持有 CloudKit 镜像。")
        }
        guard let modelURL = Bundle.main.url(forResource: "Model", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw PrototypeError.unavailable("未找到版本化数据模型。")
        }
        let storeURL = directory.appendingPathComponent("tasks.sqlite")
        if isExtension {
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                throw PrototypeError.unavailable("请先打开主应用建库。Widget 未创建空库。")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let writer = try StoreFileLock(url: directory.appendingPathComponent("write.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(writer) {} }
        let lease = try StoreFileLock(url: directory.appendingPathComponent("model.lock"), mode: LOCK_SH)
        let exists = FileManager.default.fileExists(atPath: storeURL.path)
        let compatible: Bool
        if exists {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: storeURL, options: nil)
            compatible = model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        } else { compatible = false }
        if !compatible {
            guard !isExtension else {
                throw PrototypeError.unavailable("模型不兼容，请打开主应用升级。Widget 未迁移。")
            }
            // No open app/extension may retain the old model while migration runs.
            try lease.changeMode(LOCK_EX)
        }
        if mirrored {
            guard Self.mirrorOwners.insert(directory).inserted else {
                throw PrototypeError.unavailable("本进程已有同一存储的镜像实例。")
            }
        }
        let persistent: NSPersistentContainer
        if cloudID != nil {
            persistent = NSPersistentCloudKitContainer(name: "Model", managedObjectModel: model)
        } else {
            persistent = NSPersistentContainer(name: "Model", managedObjectModel: model)
        }
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = !isExtension
        description.shouldInferMappingModelAutomatically = !isExtension
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        #if os(iOS)
        description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                              forKey: NSPersistentStoreFileProtectionKey)
        #endif
        if let cloudID {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudID)
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
        }
        persistent.persistentStoreDescriptions = [description]
        var loadError: Error?
        persistent.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            if mirrored { Self.mirrorOwners.remove(directory) }
            throw loadError // Never delete/reset the original store after a loading error.
        }
        try lease.changeMode(LOCK_SH)
        container = persistent
        modelLease = lease
        persistent.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        persistent.viewContext.automaticallyMergesChangesFromParent = true
        persistent.viewContext.transactionAuthor = isExtension ? "widget" : "app"
        let tokenURL = directory.appendingPathComponent(isExtension ? "history-widget.token" : "history-app.token")
        if let data = try? Data(contentsOf: tokenURL) {
            // Invalid recovery material can be replayed from the start; it must
            // not strand an already opened mirror or discard the database.
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
        }
        let observerGeneration = callbackGeneration
        let persistentID = ObjectIdentifier(persistent)
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
                                                          object: persistent.persistentStoreCoordinator,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCallback(generation: observerGeneration, containerID: persistentID) else {
                    return
                }
                do { try self.consumeHistory(); self.onChange?() }
                catch { self.onSyncEvent?("本机历史读取失败；本机数据保留") }
            }
        }
        if mirrored {
            eventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification, object: persistent, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { return }
                let direction: CloudSyncDirection
                let name: String
                switch event.type {
                case .import:
                    direction = .import
                    name = "导入"
                case .export:
                    direction = .export
                    name = "导出"
                case .setup:
                    direction = .setup
                    name = "建立连接"
                @unknown default:
                    return
                }
                let eventID = event.identifier
                let cloudEvent = CloudSyncEvent(
                    id: eventID,
                    direction: direction,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    succeeded: event.succeeded,
                    failure: event.error.map { CloudSyncFailure(error: $0) }
                )
                let outcome: String
                if let failure = cloudEvent.failure {
                    outcome = "failure-\(failure.rawValue)"
                } else if cloudEvent.endDate == nil {
                    outcome = "running"
                } else if cloudEvent.succeeded {
                    outcome = "success"
                } else {
                    outcome = "failure-unknown"
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.acceptsCallback(generation: observerGeneration, containerID: persistentID) else {
                        return
                    }
                    self.record("cloud.\(name)", actionID: eventID, outcome: outcome)
                    self.syncStatus.apply(cloudEvent)
                    self.onSyncEvent?(self.syncStatus.summary)
                    do { try self.consumeHistory(); self.onChange?() }
                    catch { self.onSyncEvent?("历史读取失败；本机数据保留") }
                }
            }
        }
        record("store.open", outcome: mirrored ? "cloud-mirror" : isExtension ? "extension-local" : "local")
    }

    func close() throws {
        callbackGeneration = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        observer = nil
        eventObserver = nil
        onChange = nil
        onSyncEvent = nil
        guard let container else { return }
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        self.container = nil
        modelLease = nil
        if mirrored { Self.mirrorOwners.remove(directory) }
    }

    private func matching(_ id: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        return try context.fetch(request)
    }

    private func sessionAccess() throws -> StoreFileLock? {
        _ = try context
        guard let session else { return nil }
        let base = directory.deletingLastPathComponent()
        let lock = try StoreFileLock(url: base.appendingPathComponent("session.lock"), mode: LOCK_SH)
        let published = try StoreSession.readPublished(at: base)
        let isolatedInbox = !session.ready && session.namespace == "local-inbox" && session.accountHash == nil
        guard session.modelVersion == StoreSession.modelVersion,
              directory.lastPathComponent == session.namespace,
              isolatedInbox ? !published.ready : (session.ready && published == session) else {
            throw PrototypeError.unavailable("账户或模型门禁已变化；没有访问旧库，请重新打开应用。")
        }
        return lock
    }

    private func write<T>(_ action: String, id: UUID, actionID: UUID = UUID(),
                          _ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let start = ContinuousClock.now
        let access = try sessionAccess()
        let lock = try StoreFileLock(url: directory.appendingPathComponent("write.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime((access, lock)) {} }
        let context = try context
        let previousAuthor = context.transactionAuthor
        context.transactionAuthor = "\(isExtension ? "widget" : "app"):\(actionID.uuidString)"
        defer { context.transactionAuthor = previousAuthor }
        context.refreshAllObjects()
        do {
            let result = try body(context)
            if context.hasChanges { try context.save() }
            let duration = start.duration(to: .now)
            let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            record(action, id: id, actionID: actionID, milliseconds: ms, outcome: "committed")
            onChange?()
            return result
        } catch {
            context.rollback()
            record(action, id: id, actionID: actionID, outcome: "error-\((error as NSError).domain)-\((error as NSError).code)")
            throw error
        }
    }

    @discardableResult
    func createTask(id: UUID, title: String, schedule: TaskSchedule = .none,
                    body: String = "", formatting: NoteFormatting? = nil) throws -> UUID {
        let title = try Self.validTitle(title)
        let scheduleData = try JSONEncoder().encode(schedule.validated())
        guard body.utf8.count <= 1_000_000 else { throw PrototypeError.invalid("正文超过 1 MB，当前输入已保留。") }
        let formatting = try formatting?.validated(for: body)
        return try write("task.create", id: id) { context in
            if try !matching(id).isEmpty { return id }
            let item = NSEntityDescription.insertNewObject(forEntityName: "TaskItem", into: context)
            item.setValue(id, forKey: "id")
            item.setValue(UUID().uuidString, forKey: "recordKey")
            item.setValue(title, forKey: "title")
            item.setValue(Date(), forKey: "createdAt")
            item.setValue(Date(), forKey: "updatedAt")
            item.setValue(String(data: scheduleData, encoding: .utf8), forKey: "scheduleJSON")
            if !body.isEmpty {
                try appendNote(in: context, tasks: [item], taskID: id, id: id,
                               body: body, formatting: formatting, parents: [])
            }
            return id
        }
    }

    func updateTitle(id: UUID, title: String) throws {
        let title = try Self.validTitle(title)
        try mutate("task.title", id: id) { $0.setValue(title, forKey: "title") }
    }

    func scheduleTask(id: UUID, schedule: TaskSchedule) throws {
        let data = try JSONEncoder().encode(schedule.validated())
        guard let value = String(data: data, encoding: .utf8) else { throw PrototypeError.invalid("日期编码失败。") }
        try mutate("task.schedule", id: id) { $0.setValue(value, forKey: "scheduleJSON") }
    }

    @discardableResult
    func setCompleted(id: UUID, completed: Bool) throws -> UUID {
        let actionID = UUID()
        try mutate("task.complete", id: id, actionID: actionID) {
            if completed {
                if $0.value(forKey: "completedAt") == nil { $0.setValue(Date(), forKey: "completedAt") }
            } else { $0.setValue(nil, forKey: "completedAt") }
        }
        return actionID
    }

    func moveToTrash(id: UUID) throws {
        try mutate("task.trash", id: id) { $0.setValue(Date(), forKey: "deletedAt") }
    }

    func restoreTask(id: UUID) throws {
        try mutate("task.restore", id: id, allowTrashed: true) { $0.setValue(nil, forKey: "deletedAt") }
    }

    private func mutate(_ action: String, id: UUID, actionID: UUID = UUID(), allowTrashed: Bool = false,
                        _ body: (NSManagedObject) throws -> Void) throws {
        try write(action, id: id, actionID: actionID) { _ in
            let items = try matching(id)
            guard !items.isEmpty else { throw PrototypeError.missingTask }
            guard allowTrashed || items.allSatisfy({ $0.value(forKey: "deletedAt") == nil }) else { throw PrototypeError.trashed }
            for item in items {
                try body(item)
                item.setValue(Date(), forKey: "updatedAt")
            }
        }
    }

    func saveNoteRevision(taskID: UUID, id: UUID, body: String, parentIDs: [UUID],
                          formatting: NoteFormatting? = nil) throws {
        guard body.utf8.count <= 1_000_000, !parentIDs.contains(id) else {
            throw PrototypeError.invalid("正文超过 1 MB 或父版本无效。")
        }
        try write("note.append", id: id) { context in
            let tasks = try matching(taskID)
            guard !tasks.isEmpty else { throw PrototypeError.missingTask }
            guard tasks.allSatisfy({ $0.value(forKey: "deletedAt") == nil }) else { throw PrototypeError.trashed }
            try appendNote(in: context, tasks: tasks, taskID: taskID, id: id,
                           body: body, formatting: formatting, parents: parentIDs)
        }
    }

    func updateContent(id: UUID, title: String, revisionID: UUID, body: String,
                       formatting: NoteFormatting?, parentIDs: [UUID]) throws {
        let title = try Self.validTitle(title)
        guard body.utf8.count <= 1_000_000 else { throw PrototypeError.invalid("正文超过 1 MB，当前输入已保留。") }
        let formatting = try formatting?.validated(for: body)
        try write("task.edit", id: id) { context in
            let tasks = try matching(id)
            guard !tasks.isEmpty else { throw PrototypeError.missingTask }
            guard tasks.allSatisfy({ $0.value(forKey: "deletedAt") == nil }) else { throw PrototypeError.trashed }
            let request = NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision")
            request.predicate = NSPredicate(format: "taskID == %@", id as NSUUID)
            let notes = try context.fetch(request).map { try readRevision($0) }
            let parents = Set(parentIDs)
            let baseline = parents.count == 1 ? notes.first { parents.contains($0.id) } : nil
            // Compare with the editor's parent, rather than overwriting a new remote head
            // merely because the user changed the title while reading an older version.
            let noteChanged = baseline.map { $0.body != body || $0.formatting != formatting }
                ?? (!body.isEmpty || formatting != nil || !parents.isEmpty)
            for task in tasks where task.value(forKey: "title") as? String != title {
                task.setValue(title, forKey: "title")
                task.setValue(Date(), forKey: "updatedAt")
            }
            if noteChanged {
                try appendNote(in: context, tasks: tasks, taskID: id, id: revisionID,
                               body: body, formatting: formatting, parents: parentIDs)
            }
        }
    }

    private func appendNote(in context: NSManagedObjectContext, tasks: [NSManagedObject], taskID: UUID,
                            id: UUID, body: String, formatting: NoteFormatting?, parents: [UUID]) throws {
        guard body.utf8.count <= 1_000_000, !parents.contains(id) else {
            throw PrototypeError.invalid("正文超过 1 MB 或父版本无效。")
        }
        let formattingJSON = try formatting?.encoded(for: body)
        let formatting = try NoteFormatting.decode(formattingJSON, body: body)
        let parents = Array(Set(parents)).sorted { $0.uuidString < $1.uuidString }
        let request = NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        let existing = try context.fetch(request).map { try readRevision($0) }
        if !existing.isEmpty {
            guard existing.allSatisfy({ $0.taskID == taskID && $0.body == body && $0.formatting == formatting && Set($0.parentIDs) == Set(parents) }) else {
                throw PrototypeError.invalid("相同正文版本 UUID 的内容不同，未覆盖。")
            }
            return
        }
        request.predicate = NSPredicate(format: "taskID == %@", taskID as NSUUID)
        var previous: [UUID: NoteRevision] = [:]
        for value in try context.fetch(request).map({ try readRevision($0) }) {
            if let old = previous[value.id], old.body != value.body || old.formatting != value.formatting || Set(old.parentIDs) != Set(value.parentIDs) {
                throw PrototypeError.invalid("正文身份冲突；原记录保留。")
            }
            previous[value.id] = value
        }
        try NoteRevision.validateGraph(Array(previous.values) + [NoteRevision(id: id, taskID: taskID, body: body, parentIDs: parents, createdAt: Date(), formatting: formatting)])
        let revision = NSEntityDescription.insertNewObject(forEntityName: "TaskNoteRevision", into: context)
        revision.setValue(id, forKey: "id")
        revision.setValue(taskID, forKey: "taskID")
        revision.setValue(body, forKey: "body")
        revision.setValue(formattingJSON, forKey: "formattingJSON")
        revision.setValue(Date(), forKey: "createdAt")
        revision.setValue(String(data: try JSONEncoder().encode(parents), encoding: .utf8), forKey: "parentIDsJSON")
        revision.setValue(tasks.first, forKey: "task")
        for task in tasks {
            task.setValue(id, forKey: "currentRevisionID")
            task.setValue(Date(), forKey: "updatedAt")
        }
    }

    private func readRevision(_ note: NSManagedObject) throws -> NoteRevision {
        guard let id = note.value(forKey: "id") as? UUID,
              let taskID = note.value(forKey: "taskID") as? UUID,
              let body = note.value(forKey: "body") as? String,
              let createdAt = note.value(forKey: "createdAt") as? Date,
              let parents = note.value(forKey: "parentIDsJSON") as? String else {
            throw PrototypeError.unavailable("正文记录字段尚不完整，等待同步；记录已保留。")
        }
        guard body.utf8.count <= 1_000_000 else { throw PrototypeError.invalid("正文异常过大，原记录保留。") }
        return NoteRevision(id: id, taskID: taskID, body: body,
                            parentIDs: try JSONDecoder().decode([UUID].self, from: Data(parents.utf8)), createdAt: createdAt,
                            formatting: try NoteFormatting.decode(note.value(forKey: "formattingJSON") as? String, body: body))
    }

    func snapshots() throws -> [TaskSnapshot] {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let context = try context
        context.refreshAllObjects()
        let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision"))
        var revisions: [UUID: NoteRevision] = [:]
        for note in notes {
            let value = try readRevision(note)
            let id = value.id
            if let previous = revisions[id] {
                guard previous.body == value.body, previous.formatting == value.formatting,
                      previous.taskID == value.taskID, Set(previous.parentIDs) == Set(value.parentIDs) else {
                    throw PrototypeError.invalid("正文身份冲突；原记录保留，请检查诊断。")
                }
                if previous.createdAt <= value.createdAt { continue }
            }
            revisions[id] = value
        }
        try NoteRevision.validateGraph(Array(revisions.values))
        let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TaskItem"))
        var groups: [UUID: [NSManagedObject]] = [:]
        for object in objects {
            guard let id = object.value(forKey: "id") as? UUID else {
                throw PrototypeError.unavailable("任务身份尚未到达，等待同步；记录已保留。")
            }
            groups[id, default: []].append(object)
        }
        var results: [TaskSnapshot] = []
        for (id, group) in groups {
            // CloudKit has no unique constraint. The record key gives all devices a stable projection.
            let object = group.sorted {
                ($0.value(forKey: "recordKey") as? String ?? "") < ($1.value(forKey: "recordKey") as? String ?? "")
            }[0]
            guard let title = object.value(forKey: "title") as? String,
                  let createdAt = object.value(forKey: "createdAt") as? Date,
                  let updatedAt = object.value(forKey: "updatedAt") as? Date,
                  let scheduleJSON = object.value(forKey: "scheduleJSON") as? String else {
                throw PrototypeError.unavailable("任务字段尚不完整，等待同步；记录已保留。")
            }
            let schedule = try JSONDecoder().decode(TaskSchedule.self, from: Data(scheduleJSON.utf8)).validated()
            results.append(TaskSnapshot(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                                        completedAt: object.value(forKey: "completedAt") as? Date,
                                        deletedAt: group.compactMap { $0.value(forKey: "deletedAt") as? Date }.min(),
                                        schedule: schedule, currentRevisionID: object.value(forKey: "currentRevisionID") as? UUID,
                                        revisions: revisions.values.filter { $0.taskID == id }.sorted { $0.id.uuidString < $1.id.uuidString }))
        }
        return results.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    func archive() throws -> TaskArchive {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let context = try context
        try context.setQueryGenerationFrom(.current)
        defer { try? context.setQueryGenerationFrom(nil) }
        let tasks = try snapshots()
        let ids = Set(tasks.map(\.id))
        let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision"))
        guard notes.allSatisfy({ ($0.value(forKey: "taskID") as? UUID).map { ids.contains($0) } == true }) else {
            throw PrototypeError.unavailable("部分正文的任务尚未同步到达，未导出不完整备份；记录仍保留。")
        }
        return TaskArchive(formatVersion: 1, modelVersion: StoreSession.modelVersion,
                           exportedAt: Date(), tasks: tasks)
    }

    func saveDraft(_ draft: LocalDraft) throws {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        guard !isExtension, draft.formatVersion == 1, draft.title.utf8.count <= 8_192,
              draft.body.utf8.count <= 1_000_000, !draft.parentIDs.contains(draft.id) else {
            throw PrototypeError.invalid("草稿格式或长度无效；当前输入仍在编辑器中。")
        }
        _ = try draft.formatting?.validated(for: draft.body)
        let folder = directory.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(draft)
        let url = folder.appendingPathComponent(draft.id.uuidString + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func drafts() throws -> [LocalDraft] {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let folder = directory.appendingPathComponent("drafts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else { throw PrototypeError.invalid("草稿异常过大；原文件保留。") }
                let draft = try JSONDecoder().decode(LocalDraft.self, from: data)
                guard draft.formatVersion == 1, url.deletingPathExtension().lastPathComponent == draft.id.uuidString else {
                    throw PrototypeError.invalid("草稿版本或身份不匹配；原文件保留。")
                }
                _ = try draft.formatting?.validated(for: draft.body)
                return draft
            }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func removeDraft(id: UUID) throws {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let url = directory.appendingPathComponent("drafts/\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func restoreIntoEmptyLocalStore(_ archive: TaskArchive) throws {
        guard !mirrored, !isExtension else { throw PrototypeError.invalid("M0 只允许恢复到空的隔离本地库。") }
        let verified = try TaskArchive.decode(archive.encoded())
        try write("archive.restore", id: UUID()) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
            guard try context.count(for: request) == 0 else {
                throw PrototypeError.invalid("目标库非空；未覆盖。请选择新的 M0 测试命名空间。")
            }
            for task in verified.tasks {
                let item = NSEntityDescription.insertNewObject(forEntityName: "TaskItem", into: context)
                for (key, value) in ["id": task.id, "recordKey": UUID().uuidString, "title": task.title,
                                     "createdAt": task.createdAt, "updatedAt": task.updatedAt] as [String: Any] {
                    item.setValue(value, forKey: key)
                }
                item.setValue(task.completedAt, forKey: "completedAt")
                item.setValue(task.deletedAt, forKey: "deletedAt")
                item.setValue(task.currentRevisionID, forKey: "currentRevisionID")
                item.setValue(String(data: try JSONEncoder().encode(task.schedule), encoding: .utf8), forKey: "scheduleJSON")
                for note in task.revisions {
                    let revision = NSEntityDescription.insertNewObject(forEntityName: "TaskNoteRevision", into: context)
                    revision.setValue(note.id, forKey: "id")
                    revision.setValue(note.taskID, forKey: "taskID")
                    revision.setValue(note.body, forKey: "body")
                    revision.setValue(try note.formatting?.encoded(for: note.body), forKey: "formattingJSON")
                    revision.setValue(note.createdAt, forKey: "createdAt")
                    revision.setValue(String(data: try JSONEncoder().encode(note.parentIDs), encoding: .utf8), forKey: "parentIDsJSON")
                    revision.setValue(item, forKey: "task")
                }
            }
        }
    }

    func consumeHistory() throws {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let context = try context
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction], !transactions.isEmpty else { return }
        for transaction in transactions {
            if let info = transaction.objectIDNotification().userInfo {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: info, into: [context])
            }
        }
        guard let latest = transactions.last?.token else { return }
        let data = try NSKeyedArchiver.archivedData(withRootObject: latest, requiringSecureCoding: true)
        try data.write(to: directory.appendingPathComponent(isExtension ? "history-widget.token" : "history-app.token"), options: .atomic)
        token = latest // A failed token write must not acknowledge transactions only in memory.
    }

    func record(_ action: String, id: UUID? = nil, actionID: UUID = UUID(),
                milliseconds: Double? = nil, outcome: String = "observed") {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entry: [String: Any] = ["time": formatter.string(from: Date()), "action": action,
                                  "eventFormatVersion": 2, "eventID": UUID().uuidString, "actionID": actionID.uuidString,
                                  "pid": ProcessInfo.processInfo.processIdentifier,
                                  "process": isExtension ? "extension" : "app", "modelVersion": StoreSession.modelVersion,
                                  "outcome": outcome]
        if let id { entry["subjectID"] = id.uuidString }
        if let milliseconds { entry["milliseconds"] = milliseconds }
        do {
            let url = directory.appendingPathComponent("events.jsonl")
            let descriptor = open(url.path, O_CREAT | O_APPEND | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw PrototypeError.unavailable("无法记录证据。") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw PrototypeError.busy }
            defer { flock(descriptor, LOCK_UN) }
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            Self.logger.info("\(action, privacy: .public) \(outcome, privacy: .public)")
        } catch {
            Self.logger.error("Evidence write failed: \((error as NSError).code, privacy: .public)")
        }
    }
}
