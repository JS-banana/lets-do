import CloudKit
import CryptoKit
import Darwin
import Foundation
import OSLog

// The same advisory lock protocol is used by both executables. A model lease
// lasts as long as an open container; session leases cover each local operation.
final class StoreFileLock {
    private let descriptor: Int32

    init(url: URL, mode: Int32) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw PrototypeError.unavailable("无法锁定共享存储；原库未改动。") }
        guard flock(descriptor, mode | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw PrototypeError.busy
        }
        self.descriptor = descriptor
    }

    func changeMode(_ mode: Int32) throws {
        guard flock(descriptor, mode | LOCK_NB) == 0 else { throw PrototypeError.busy }
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

enum PrototypeError: LocalizedError {
    case invalid(String)
    case unavailable(String)
    case missingTask
    case trashed
    case busy

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        case .missingTask: "任务已不存在，请打开应用检查。"
        case .trashed: "任务已在回收站。请先明确恢复，再编辑。"
        case .busy: "另一个入口正在保存，请稍后重试。"
        }
    }
}

struct StoreSession: Codable, Equatable, Sendable {
    let modelVersion: Int
    let namespace: String
    let accountHash: String?
    let cloudEnabled: Bool
    let ready: Bool

    static let modelVersion = 2

    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "M0AppGroup") as? String ?? ""
    }

    static var cloudID: String {
        Bundle.main.object(forInfoDictionaryKey: "M0CloudContainer") as? String ?? ""
    }

    static var isLocalBuild: Bool {
        #if M0_LOCAL
        true
        #else
        false
        #endif
    }

    static var isDesktopLocalBuild: Bool {
        #if os(macOS) && M0_DESKTOP
        true
        #else
        false
        #endif
    }

    static var supportsCloudSync: Bool { !isLocalBuild && !isDesktopLocalBuild }

    static func baseURL() throws -> URL {
        if isLocalBuild {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
            return base.appendingPathComponent("TodoM0/Local", isDirectory: true)
        }
        guard !groupID.isEmpty,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw PrototypeError.unavailable("M0 App Group 不可用，请检查签名与权限。没有另建替代库。")
        }
        return group.appendingPathComponent(isDesktopLocalBuild ? "TodoM0/DesktopLocal" : "TodoM0/Development", isDirectory: true)
    }

    func directory() throws -> URL {
        guard modelVersion == Self.modelVersion,
              namespace.range(of: "^[a-zA-Z0-9-]{1,100}$", options: .regularExpression) != nil else {
            throw PrototypeError.invalid("存储版本或命名空间不兼容，请打开主应用。")
        }
        return try Self.baseURL().appendingPathComponent(namespace, isDirectory: true)
    }

    static func local() -> StoreSession {
        StoreSession(modelVersion: modelVersion, namespace: "local-\(requestedRunName ?? "manual")",
                     accountHash: nil, cloudEnabled: false, ready: true)
    }

    private static var requestedRunName: String? {
        // A launch argument isolates UI automation from the manual prototype store.
        let args = ProcessInfo.processInfo.arguments
        let run = args.firstIndex(of: "-M0Run").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        return run?.range(of: "^[a-zA-Z0-9-]{1,70}$", options: .regularExpression) != nil ? run : nil
    }

    static func confirmedAccount() async throws -> String? {
        guard !cloudID.isEmpty else { throw PrototypeError.unavailable("未配置 M0 CloudKit 容器。") }
        let cloud = CKContainer(identifier: cloudID)
        let logger = Logger(subsystem: "com.panion.todo.m0", category: "account")
        let lookupID = UUID().uuidString
        var phase = "account-status"
        var started = ContinuousClock.now
        // System log supplies time and PID; never include the account ID or hash.
        func trace(_ outcome: String) {
            let elapsed = started.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
            logger.notice("account.lookup id=\(lookupID, privacy: .public) phase=\(phase, privacy: .public) outcome=\(outcome, privacy: .public) milliseconds=\(ms, privacy: .public)")
        }
        trace("begin")
        do {
            let status = try await cloud.accountStatus()
            trace("status-\(status.rawValue)")
            switch status {
            case .available:
                phase = "user-record-id"
                started = .now
                trace("begin")
                let id = try await cloud.userRecordID()
                trace("confirmed")
                return SHA256.hash(data: Data(id.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
            case .noAccount: return nil
            case .restricted:
                throw PrototypeError.unavailable("此设备限制了 iCloud 访问。请在系统设置中检查账户限制；云库与草稿已保留。")
            case .temporarilyUnavailable:
                throw PrototypeError.unavailable("iCloud 暂时不可用，请稍后检查；云库与草稿已保留。")
            default:
                throw PrototypeError.unavailable("暂时无法确认 iCloud 账户，请检查系统设置与网络后重试；云库与草稿已保留。")
            }
        } catch {
            trace("error-\((error as NSError).code)")
            if error is PrototypeError { throw error }
            if let cloudError = error as? CKError {
                switch cloudError.code {
                case .networkUnavailable, .networkFailure:
                    throw PrototypeError.unavailable("无法连接 iCloud，请检查网络后重试；云库与草稿已保留。")
                case .badContainer, .missingEntitlement, .permissionFailure:
                    throw PrototypeError.unavailable("此版本尚未取得 iCloud 访问权限。请使用已配置云同步的版本；原有数据已保留。")
                default: break
                }
            }
            throw PrototypeError.unavailable("暂时无法确认 iCloud 账户，请稍后检查；云库与草稿已保留。")
        }
    }

    // A local inbox never becomes a mirror. Switching modes selects a separate
    // library, and returning to an account selects that account's existing one.
    static func cloudSession(syncEnabled: Bool, accountHash: String?) throws -> StoreSession {
        guard syncEnabled, let accountHash else {
            return StoreSession(modelVersion: modelVersion, namespace: "local-inbox",
                                accountHash: nil, cloudEnabled: false, ready: true)
        }
        guard accountHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw PrototypeError.invalid("无法确认 iCloud 账户标识；没有打开云库。")
        }
        return StoreSession(modelVersion: modelVersion, namespace: "account-\(accountHash)",
                            accountHash: accountHash, cloudEnabled: true, ready: true)
    }

    static func publish(_ session: StoreSession) throws {
        let base = try baseURL()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = try StoreFileLock(url: base.appendingPathComponent("session.lock"), mode: LOCK_EX)
        defer { withExtendedLifetime(lock) {} }
        let data = try JSONEncoder().encode(session)
        try data.write(to: base.appendingPathComponent("session.json"), options: .atomic)
    }

    static func readPublished(at base: URL) throws -> StoreSession {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: base.appendingPathComponent("session.json")))
    }

    @discardableResult
    static func blockExtensions() throws -> StoreSession {
        var namespace = "blocked"
        if isDesktopLocalBuild {
            let base = try baseURL()
            let previous = FileManager.default.fileExists(atPath: base.appendingPathComponent("session.json").path)
                ? try readPublished(at: base) : nil
            namespace = try desktopNamespace(run: requestedRunName, previous: previous)
        }
        let blocked = StoreSession(modelVersion: modelVersion, namespace: namespace, accountHash: nil,
                                   cloudEnabled: false, ready: false)
        try publish(blocked)
        return blocked
    }

    // A cold Widget link has no launch arguments. Keep the last DesktopLocal
    // library even while extensions are blocked; never infer a cloud library.
    static func desktopNamespace(run: String?, previous: StoreSession?) throws -> String {
        if let previous {
            guard (1...modelVersion).contains(previous.modelVersion), previous.accountHash == nil,
                  !previous.cloudEnabled,
                  previous.namespace.range(of: "^desktop-[a-zA-Z0-9-]{1,70}$", options: .regularExpression) != nil else {
                throw PrototypeError.unavailable("桌面任务库记录不兼容，原库与草稿已保留。")
            }
        }
        let namespace = run.map { "desktop-\($0)" } ?? previous?.namespace ?? "desktop-manual"
        guard namespace.range(of: "^desktop-[a-zA-Z0-9-]{1,70}$", options: .regularExpression) != nil else {
            throw PrototypeError.invalid("无效的桌面测试库名称。")
        }
        return namespace
    }

    static func forMainApp(blockedSession: StoreSession?, cloudSyncEnabled: Bool) async throws -> StoreSession {
        if isLocalBuild { return local() }
        if isDesktopLocalBuild {
            guard let blockedSession, !blockedSession.ready, blockedSession.modelVersion == modelVersion else {
                throw PrototypeError.unavailable("桌面任务库尚未完成本次启动检查。")
            }
            let namespace = try desktopNamespace(run: nil, previous: blockedSession)
            return StoreSession(modelVersion: modelVersion, namespace: namespace,
                                accountHash: nil, cloudEnabled: false, ready: true)
        }
        let account = cloudSyncEnabled ? try await confirmedAccount() : nil
        return try cloudSession(syncEnabled: cloudSyncEnabled, accountHash: account)
    }

    static func forExtension() async throws -> StoreSession {
        guard !isLocalBuild else {
            throw PrototypeError.unavailable("请使用已签名的桌面本机版或 CloudDevelopment 添加系统小组件。")
        }
        let base = try baseURL()
        let session = try readPublished(at: base)
        guard session.ready, session.modelVersion == modelVersion else {
            throw PrototypeError.unavailable("请先打开主应用完成账户与模型检查。")
        }
        if isDesktopLocalBuild {
            guard session.namespace.hasPrefix("desktop-"), session.accountHash == nil, !session.cloudEnabled,
                  try readPublished(at: base) == session else {
                throw PrototypeError.unavailable("桌面任务库已切换，请刷新小组件；没有访问其他任务库。")
            }
            _ = try session.directory()
            return session
        }
        // Explicitly local sessions are safe without an online identity lookup.
        // Cloud sessions still confirm the identity on every extension access.
        let account = session.cloudEnabled ? try await confirmedAccount() : nil
        guard try cloudSession(syncEnabled: session.cloudEnabled, accountHash: account) == session,
              try readPublished(at: base) == session else {
            throw PrototypeError.unavailable("iCloud 账户发生变化，请打开主应用；没有写入旧账户库。")
        }
        _ = try session.directory()
        return session
    }
}
