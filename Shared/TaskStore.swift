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
        guard cyclic(revisions).isEmpty else { throw PrototypeError.invalid("正文父版本存在循环，未覆盖原记录。") }
    }

    /// Revisions on a parent cycle or descending from one; empty for a valid history.
    static func cyclic(_ revisions: [NoteRevision]) -> Set<UUID> {
        let ids = Set(revisions.map(\.id))
        var dependencies = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, Set($0.parentIDs).intersection(ids)) })
        var children: [UUID: [UUID]] = [:]
        for revision in revisions { for parent in Set(revision.parentIDs).intersection(ids) { children[parent, default: []].append(revision.id) } }
        var ready = dependencies.filter { $0.value.isEmpty }.map(\.key)
        var visited = Set<UUID>()
        while let id = ready.popLast() {
            visited.insert(id)
            for child in children[id, default: []] {
                dependencies[child]?.remove(id)
                if dependencies[child]?.isEmpty == true { ready.append(child) }
            }
        }
        return ids.subtracting(visited)
    }
}

// Drafts are device-local recovery material, outside the Core Data model.
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
    var originalTitle: String? = nil
    /// The capture plan came from a date in the title, so removing that phrase may still change it.
    var captureScheduleFromTitle: Bool? = nil

    /// Residue of a save whose draft cleanup failed: this exact text and title are already committed.
    func isCommitted(in task: TaskSnapshot) -> Bool {
        guard let revision = task.revisions.first(where: { $0.id == id }) else { return false }
        return revision.body == body && revision.formatting == formatting
            && TaskStore.titleChange(title, from: task.title) == nil
    }

    func editorTitle(current: String) -> (text: String, baseline: String, needsChoice: Bool) {
        guard let originalTitle else {
            // A legacy draft may contain either a deliberate rename or an old copy.
            return (title, current, TaskStore.titleChange(title, from: current) != nil)
        }
        if TaskStore.titleChange(title, from: originalTitle) == nil {
            return (current, current, false)
        }
        return (title, originalTitle, false)
    }
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
        let data = try encoder.encode(self)
        try Self.checkSize(data)
        return data
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= 20_000_000 else {
            throw PrototypeError.invalid("JSON 备份超过 20 MB，无法导出或恢复。原库已保留。")
        }
    }

    static func decode(_ data: Data) throws -> Self {
        try checkSize(data)
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

// Main-queue contexts stay here. Views and intents receive only value snapshots/UUIDs.
@MainActor
final class TaskStore {
    private(set) var container: NSPersistentContainer?
    let directory: URL
    let isExtension: Bool
    private let session: StoreSession?
    private var modelLease: StoreFileLock?
    private var observer: NSObjectProtocol?
    private var token: NSPersistentHistoryToken?
    private var callbackGeneration = UUID()
    var onChange: (() -> Void)?
    var onHistoryReadFailure: (() -> Void)?
    private static let logger = Logger(subsystem: "com.panion.letsdo", category: "store")

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

    nonisolated static func titleChange(_ title: String, from original: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : trimmed
    }

    init(directory: URL, isExtension: Bool = false, session: StoreSession? = nil) throws {
        self.directory = directory
        self.isExtension = isExtension
        self.session = session
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
        let persistent = NSPersistentContainer(name: "Model", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = !isExtension
        description.shouldInferMappingModelAutomatically = !isExtension
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        persistent.persistentStoreDescriptions = [description]
        var loadError: Error?
        persistent.loadPersistentStores { _, error in loadError = error }
        if let loadError {
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
            // not prevent opening the store or discard the database.
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
                catch { self.onHistoryReadFailure?() }
            }
        }
        record("store.open", outcome: isExtension ? "extension-local" : "local")
    }

    func close() throws {
        callbackGeneration = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onChange = nil
        onHistoryReadFailure = nil
        guard let container else { return }
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        self.container = nil
        modelLease = nil
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
        guard session.ready, session.modelVersion == StoreSession.modelVersion,
              directory.lastPathComponent == session.namespace, published == session else {
            throw PrototypeError.unavailable("存储会话或模型已变化；没有访问旧库，请重新打开应用。")
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
    func setCompleted(id: UUID, completed: Bool, actionID: UUID? = nil) throws -> UUID {
        let completionActionID = actionID ?? UUID()
        try mutate("task.complete", id: id, actionID: completionActionID,
                   skipCommittedAction: actionID != nil) {
            if completed {
                if $0.value(forKey: "completedAt") == nil { $0.setValue(Date(), forKey: "completedAt") }
            } else { $0.setValue(nil, forKey: "completedAt") }
        }
        return completionActionID
    }

    func moveToTrash(id: UUID) throws {
        try mutate("task.trash", id: id) { $0.setValue(Date(), forKey: "deletedAt") }
    }

    func restoreTask(id: UUID) throws {
        try mutate("task.restore", id: id, allowTrashed: true) { $0.setValue(nil, forKey: "deletedAt") }
    }

    // A caller may reuse an action UUID only to retry the same write. History is saved
    // atomically with the task and retained even after consumeHistory advances its cursor.
    private func hasCommittedAction(_ actionID: UUID, in context: NSManagedObjectContext) throws -> Bool {
        guard let entity = NSPersistentHistoryTransaction.entityDescription(with: context) else {
            throw PrototypeError.unavailable("无法核对已提交的完成操作；任务保持原状。")
        }
        let transactions = NSFetchRequest<NSFetchRequestResult>()
        transactions.entity = entity
        transactions.predicate = NSPredicate(format: "author IN %@", ["app:\(actionID.uuidString)", "widget:\(actionID.uuidString)"])
        transactions.fetchLimit = 1
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
        request.fetchRequest = transactions
        request.resultType = .transactionsOnly
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              result.resultType == .transactionsOnly,
              let history = result.result as? [NSPersistentHistoryTransaction] else {
            throw PrototypeError.unavailable("无法核对已提交的完成操作；任务保持原状。")
        }
        return !history.isEmpty
    }

    private func mutate(_ action: String, id: UUID, actionID: UUID = UUID(), allowTrashed: Bool = false,
                        skipCommittedAction: Bool = false,
                        _ body: (NSManagedObject) throws -> Void) throws {
        try write(action, id: id, actionID: actionID) { context in
            if skipCommittedAction, try hasCommittedAction(actionID, in: context) { return }
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

    func updateContent(id: UUID, title: String?, revisionID: UUID, body: String,
                       formatting: NoteFormatting?, parentIDs: [UUID]) throws {
        let title = try title.map(Self.validTitle)
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
            if let title {
                for task in tasks where task.value(forKey: "title") as? String != title {
                    task.setValue(title, forKey: "title")
                    task.setValue(Date(), forKey: "updatedAt")
                }
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
            throw PrototypeError.unavailable("正文记录字段不完整，原记录已保留。")
        }
        guard body.utf8.count <= 1_000_000 else { throw PrototypeError.invalid("正文异常过大，原记录保留。") }
        return NoteRevision(id: id, taskID: taskID, body: body,
                            parentIDs: try JSONDecoder().decode([UUID].self, from: Data(parents.utf8)), createdAt: createdAt,
                            formatting: try NoteFormatting.decode(note.value(forKey: "formattingJSON") as? String, body: body))
    }

    struct ReadableTasks: Sendable {
        let tasks: [TaskSnapshot]
        /// Existing tasks left out because one of their records cannot be read.
        let unreadableIDs: Set<UUID>
        /// Task records that cannot be read and have no task UUID yet.
        let anonymousTasks: Int
        var unreadableCount: Int { unreadableIDs.count + anonymousTasks }
    }

    /// Strict read for backups, upgrades and checks: any unreadable record fails the whole read.
    func snapshots() throws -> [TaskSnapshot] {
        try readSnapshots(strict: true).tasks
    }

    /// Display read for the app and widgets. A task with an unreadable record is left out
    /// and reported, so one bad record cannot hide the rest. Nothing is modified or deleted.
    func readableSnapshots() throws -> ReadableTasks {
        try readSnapshots(strict: false)
    }

    private func readSnapshots(strict: Bool) throws -> ReadableTasks {
        let access = try sessionAccess()
        defer { withExtendedLifetime(access) {} }
        let context = try context
        context.refreshAllObjects()
        var anonymous = 0        // task records without a task UUID
        var broken = Set<UUID>() // tasks with at least one unreadable record
        func skip(_ error: Error, task: UUID?) throws {
            if strict { throw error }
            if let task { broken.insert(task) } else { anonymous += 1 }
        }
        let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TaskNoteRevision"))
        var revisions: [UUID: NoteRevision] = [:]
        for note in notes {
            let value: NoteRevision
            do { value = try readRevision(note) } catch {
                // Attribute through the relationship when the copied task UUID is missing.
                let owner = note.value(forKey: "taskID") as? UUID
                    ?? (note.value(forKey: "task") as? NSManagedObject)?.value(forKey: "id") as? UUID
                if strict { throw error }
                if let owner { broken.insert(owner) } // an ownerless note is not a task to report
                continue
            }
            let id = value.id
            if let previous = revisions[id] {
                guard previous.body == value.body, previous.formatting == value.formatting,
                      previous.taskID == value.taskID, Set(previous.parentIDs) == Set(value.parentIDs) else {
                    try skip(PrototypeError.invalid("正文身份冲突；原记录保留，请检查诊断。"), task: value.taskID)
                    broken.insert(previous.taskID)
                    continue
                }
                if previous.createdAt <= value.createdAt { continue }
            }
            revisions[id] = value
        }
        let revisionsByTask = Dictionary(grouping: revisions.values, by: \.taskID)
        if strict {
            try NoteRevision.validateGraph(Array(revisions.values))
        } else {
            // A parent cycle may span tasks; every task on or below it is unreadable.
            for id in NoteRevision.cyclic(Array(revisions.values)) {
                if let task = revisions[id]?.taskID { broken.insert(task) }
            }
        }
        let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TaskItem"))
        var groups: [UUID: [NSManagedObject]] = [:]
        for object in objects {
            guard let id = object.value(forKey: "id") as? UUID else {
                try skip(PrototypeError.unavailable("任务缺少标识，原记录已保留。"), task: nil)
                continue
            }
            groups[id, default: []].append(object)
        }
        var results: [TaskSnapshot] = []
        for (id, group) in groups where !broken.contains(id) {
            // The record key provides a stable choice among physical duplicates.
            let object = group.sorted {
                ($0.value(forKey: "recordKey") as? String ?? "") < ($1.value(forKey: "recordKey") as? String ?? "")
            }[0]
            guard let title = object.value(forKey: "title") as? String,
                  let createdAt = object.value(forKey: "createdAt") as? Date,
                  let updatedAt = object.value(forKey: "updatedAt") as? Date,
                  let scheduleJSON = object.value(forKey: "scheduleJSON") as? String else {
                try skip(PrototypeError.unavailable("任务字段不完整，原记录已保留。"), task: id)
                continue
            }
            let schedule: TaskSchedule
            do { schedule = try JSONDecoder().decode(TaskSchedule.self, from: Data(scheduleJSON.utf8)).validated() }
            catch { try skip(error, task: id); continue }
            results.append(TaskSnapshot(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                                        completedAt: object.value(forKey: "completedAt") as? Date,
                                        deletedAt: group.compactMap { $0.value(forKey: "deletedAt") as? Date }.min(),
                                        schedule: schedule, currentRevisionID: object.value(forKey: "currentRevisionID") as? UUID,
                                        revisions: (revisionsByTask[id] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }))
        }
        // Report only tasks that exist; notes without a task do not constitute a task.
        let tasks = results.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        return ReadableTasks(tasks: tasks, unreadableIDs: broken.intersection(groups.keys), anonymousTasks: anonymous)
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
            throw PrototypeError.unavailable("部分正文缺少对应任务，无法导出完整备份。原记录已保留。")
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
        guard !isExtension else { throw PrototypeError.invalid("备份只能恢复到空的本机任务库；原有任务未改动。") }
        let verified = try TaskArchive.decode(archive.encoded())
        try write("archive.restore", id: UUID()) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
            guard try context.count(for: request) == 0 else {
                throw PrototypeError.invalid("当前任务库已有任务，备份没有导入。恢复只支持空的本机任务库，原有任务未改动。")
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
