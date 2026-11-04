#if os(macOS)
import CoreData
import Darwin
import Foundation

// A closed Local library changes location once. The old directory becomes an
// alias at the commit point, so an older session:nil app cannot fork its data.
@MainActor
enum LocalLibraryUpgrade {
    struct Receipt: Codable, Equatable {
        let version: Int
        let id: UUID
        let source: String
        let target: String
        let storeUUID: String

        var backupName: String { ".local-before-distribution-\(id.uuidString)" }
        var stageName: String { ".local-upgrade-\(id.uuidString)" }
    }

    private enum Item: Equatable { case missing, directory, file, link, other }
    private static let ownerName = ".local-upgrade-owner.json"

    static func prepare(source: URL, target: URL) throws {
        let fm = FileManager.default
        let source = source.standardizedFileURL, target = target.standardizedFileURL
        guard source.isFileURL, target.isFileURL, source.path != target.path,
              source.path != "/", target.path != "/",
              !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else {
            throw invalid()
        }
        // Keep the lexical URLs for receipts and the eventual alias, but a
        // real source directory must not contain (or alias) its destination.
        if try item(source) == .directory { try requireSeparateLocations(source: source, target: target) }
        let parent = target.deletingLastPathComponent()
        try require(try item(parent), oneOf: [.missing, .directory])
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let migration = try StoreFileLock(url: parent.appendingPathComponent(".\(target.lastPathComponent).upgrade.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(migration) {} }
        let receiptURL = parent.appendingPathComponent(".\(target.lastPathComponent).upgrade.json")
        let receipt: Receipt?
        switch try item(receiptURL) {
        case .missing: receipt = nil
        case .file:
            receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard let receipt, receipt.version == 1, receipt.source == source.path,
                  receipt.target == target.path, !receipt.storeUUID.isEmpty else { throw invalid() }
        default: throw invalid()
        }
        try require(try item(target), oneOf: [.missing, .directory])
        switch try item(source) {
        case .missing:
            // New installs and existing distribution libraries have no Local
            // source. Their normal TaskStore open remains responsible for checks.
            guard receipt == nil else { throw invalid() }
            return
        case .link:
            guard let receipt, try fm.destinationOfSymbolicLink(atPath: source.path) == target.path,
                  try item(target) == .directory,
                  try item(source.deletingLastPathComponent().appendingPathComponent(receipt.backupName)) == .directory else {
                throw invalid()
            }
            try verifyOwner(target, receipt: receipt)
            try require(try item(target.appendingPathComponent("tasks.sqlite")), oneOf: [.file])
            return // Committed: never restore a backup over subsequent writes.
        case .directory: break
        default: throw invalid()
        }
        try require(try item(source.deletingLastPathComponent()), oneOf: [.directory])
        let writer = try StoreFileLock(url: source.appendingPathComponent("write.lock"), mode: LOCK_EX)
        let model = try StoreFileLock(url: source.appendingPathComponent("model.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime((writer, model)) {} }
        try require(try item(source), oneOf: [.directory])
        try requireSeparateLocations(source: source, target: target)
        let sourceStore = source.appendingPathComponent("tasks.sqlite")
        try require(try item(sourceStore), oneOf: [.file])
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: sourceStore,
                                                                                  options: [NSReadOnlyPersistentStoreOption: true])
        guard let storeUUID = metadata[NSStoreUUIDKey] as? String, !storeUUID.isEmpty else { throw invalid() }
        let transaction = receipt ?? Receipt(version: 1, id: UUID(), source: source.path, target: target.path, storeUUID: storeUUID)
        guard transaction.storeUUID == storeUUID else { throw invalid() }
        let stage = parent.appendingPathComponent(transaction.stageName, isDirectory: true)
        let backup = source.deletingLastPathComponent().appendingPathComponent(transaction.backupName)

        // A prepared copy can be stale after the old app ran again. Rebuild it
        // under the original locks; only material owned by this receipt is removed.
        var targetLocks: [StoreFileLock] = []
        if try item(target) != .missing {
            guard receipt != nil else { throw invalid() }
            try verifyOwner(target, receipt: transaction)
            targetLocks = try exclusiveLocks(in: target)
        }
        defer { withExtendedLifetime(targetLocks) {} }
        try require(try item(stage), oneOf: [.missing, .directory])
        switch try item(backup) {
        case .missing: break
        case .link:
            guard receipt != nil, try fm.destinationOfSymbolicLink(atPath: backup.path) == target.path else { throw invalid() }
        default: throw invalid()
        }
        if receipt == nil { try write(transaction, to: receiptURL) }
        if try item(stage) != .missing { try fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let modelURL = Bundle.main.url(forResource: "Model", withExtension: "momd"),
              let dataModel = NSManagedObjectModel(contentsOf: modelURL) else { throw invalid() }
        let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true,
                                         NSPersistentStoreRemoteChangeNotificationPostOptionKey: true]
        var sourceOptions = options
        sourceOptions[NSReadOnlyPersistentStoreOption] = true
        try NSPersistentStoreCoordinator(managedObjectModel: dataModel).replacePersistentStore(
            at: stage.appendingPathComponent("tasks.sqlite"), destinationOptions: options,
            withPersistentStoreFrom: sourceStore, sourceOptions: sourceOptions, ofType: NSSQLiteStoreType)
        try copyDrafts(from: source, to: stage)
        let audit = source.appendingPathComponent("events.jsonl")
        if try item(audit) != .missing {
            try require(try item(audit), oneOf: [.file])
            try fm.copyItem(at: audit, to: stage.appendingPathComponent("events.jsonl"))
        }
        let verified = try TaskStore(directory: stage)
        do {
            _ = try verified.snapshots()
            _ = try verified.drafts()
            try verified.consumeHistory()
            try verified.close()
        } catch {
            try? verified.close()
            throw error
        }
        // Store history is retained; each new executable replays it from nil.
        let cursor = stage.appendingPathComponent("history-app.token")
        if try item(cursor) != .missing { try fm.removeItem(at: cursor) }
        try write(transaction, to: stage.appendingPathComponent(ownerName))
        try synchronizeTree(stage)
        let stagedLocks = try exclusiveLocks(in: stage)
        defer { withExtendedLifetime(stagedLocks) {} }
        if try item(target) != .missing { try fm.removeItem(at: target) }
        try fm.moveItem(at: stage, to: target)
        try synchronize(parent)
        if try item(backup) == .missing { try fm.createSymbolicLink(atPath: backup.path, withDestinationPath: target.path) }
        try synchronize(source.deletingLastPathComponent())
        let localParent = source.deletingLastPathComponent()
        let descriptor = open(localParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw invalid() }
        defer { Darwin.close(descriptor) }
        // Both names are in Local's parent, even when the new store is on a
        // different volume. No remove/rename fallback is safe for older apps.
        guard renameatx_np(descriptor, source.lastPathComponent, descriptor, transaction.backupName, UInt32(RENAME_SWAP)) == 0 else {
            throw PrototypeError.unavailable("无法原子切换旧任务库（系统错误 \(errno)）；旧库与准备材料已保留。")
        }
        try synchronize(localParent)
    }

    private static func exclusiveLocks(in directory: URL) throws -> [StoreFileLock] {
        [try StoreFileLock(url: directory.appendingPathComponent("write.lock"), mode: LOCK_EX),
         try StoreFileLock(url: directory.appendingPathComponent("model.lock"), mode: LOCK_EX)]
    }

    private static func requireSeparateLocations(source: URL, target: URL) throws {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        // The destination need not exist. Resolve its deepest existing
        // ancestor first, then append the missing suffix without creating it.
        var ancestor = target
        var suffix: [String] = []
        while try item(ancestor) == .missing {
            guard ancestor.path != "/" else { throw invalid() }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let resolvedTarget = suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
        guard resolvedSource.path != resolvedTarget.path,
              !resolvedTarget.path.hasPrefix(resolvedSource.path + "/"),
              !resolvedSource.path.hasPrefix(resolvedTarget.path + "/") else { throw invalid() }
    }

    private static func verifyOwner(_ directory: URL, receipt: Receipt) throws {
        let owner = directory.appendingPathComponent(ownerName)
        try require(try item(owner), oneOf: [.file])
        guard try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: owner)) == receipt else { throw invalid() }
    }

    private static func copyDrafts(from source: URL, to target: URL) throws {
        let fm = FileManager.default, drafts = source.appendingPathComponent("drafts")
        guard try item(drafts) != .missing else { return }
        try require(try item(drafts), oneOf: [.directory])
        let destination = target.appendingPathComponent("drafts", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for entry in try fm.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil) {
            try require(try item(entry), oneOf: [.file])
            try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private static func item(_ url: URL) throws -> Item {
        var information = stat()
        if lstat(url.path, &information) != 0 {
            if errno == ENOENT { return .missing }
            throw invalid()
        }
        switch information.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .link
        default: return .other
        }
    }

    private static func require(_ value: Item, oneOf allowed: [Item]) throws {
        guard allowed.contains(value) else { throw invalid() }
    }

    private static func write(_ receipt: Receipt, to url: URL) throws {
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronize(url)
        try synchronize(url.deletingLastPathComponent())
    }

    private static func synchronizeTree(_ directory: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if try item(entry) == .directory { try synchronizeTree(entry) }
            else { try require(try item(entry), oneOf: [.file]); try synchronize(entry) }
        }
        try synchronize(directory)
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw invalid() }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw invalid() }
    }

    private static func invalid() -> PrototypeError {
        .unavailable("旧版本升级记录、路径或任务库不一致；没有覆盖任务库，请保留现有文件后检查。")
    }
}
#endif
