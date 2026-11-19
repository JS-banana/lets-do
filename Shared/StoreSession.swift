import Darwin
import Foundation

// The same advisory lock protocol is used by both executables. A model lease
// lasts as long as an open container; session leases cover each local operation.
final class StoreFileLock {
    private let descriptor: Int32

    init(url: URL, mode: Int32) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw AppError.unavailable("无法锁定共享存储；原库未改动。") }
        guard flock(descriptor, mode | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AppError.busy
        }
        self.descriptor = descriptor
    }

    func changeMode(_ mode: Int32) throws {
        guard flock(descriptor, mode | LOCK_NB) == 0 else { throw AppError.busy }
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

enum AppError: LocalizedError {
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
    let ready: Bool

    static let modelVersion = 2

    static var isLocalBuild: Bool { !isMacDistributionBuild }

    static var isMacDistributionBuild: Bool {
        #if MAC_DISTRIBUTION
        true
        #else
        false
        #endif
    }

    static func baseURL() throws -> URL {
        if isMacDistributionBuild {
            let fm = FileManager.default
            return try distributionBaseURL(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                appIdentifier: Bundle.main.object(forInfoDictionaryKey: "LetsDoAppIdentifier") as? String,
                widgetIdentifier: Bundle.main.object(forInfoDictionaryKey: "LetsDoWidgetIdentifier") as? String,
                applicationSupport: fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false),
                userHome: fm.homeDirectoryForCurrentUser
            )
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return base.appendingPathComponent("LetsDo/Local", isDirectory: true)
    }

    // Resolve the shared root before reading or publishing a session there.
    static func distributionBaseURL(bundleIdentifier: String?, appIdentifier: String?, widgetIdentifier: String?,
                                    applicationSupport: URL, userHome: URL) throws -> URL {
        guard let appIdentifier, let widgetIdentifier,
              appIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+\\z", options: .regularExpression) != nil,
              widgetIdentifier == appIdentifier + ".widget",
              applicationSupport.isFileURL, userHome.isFileURL else {
            throw AppError.invalid("本机分发版的应用与小组件身份配置不匹配；没有选择其他任务库。")
        }
        let support: URL
        switch bundleIdentifier {
        case widgetIdentifier:
            support = applicationSupport
        case appIdentifier:
            support = userHome.appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(widgetIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
        default:
            throw AppError.invalid("无法确认本机分发版的进程身份；没有选择其他任务库。")
        }
        return try checkedDirectory(support.appendingPathComponent("LetsDo/MacDistribution", isDirectory: true))
    }

    // lstat inspects the directory entry itself, including dangling symbolic links.
    private static func checkedDirectory(_ url: URL) throws -> URL {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw AppError.unavailable("任务库路径不是普通目录，请检查存储位置。")
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    func directory() throws -> URL {
        guard modelVersion == Self.modelVersion,
              namespace.range(of: "^[a-zA-Z0-9-]{1,100}$", options: .regularExpression) != nil else {
            throw AppError.invalid("存储版本或命名空间不兼容，请打开主应用。")
        }
        let base = try Self.baseURL()
        if Self.isMacDistributionBuild { return try distributionDirectory(at: base) }
        return base.appendingPathComponent(namespace, isDirectory: true)
    }

    func distributionDirectory(at base: URL) throws -> URL {
        guard Self.validDistributionNamespace(namespace) else {
            throw AppError.invalid("无效的分发任务库名称。")
        }
        return try Self.checkedDirectory(base.appendingPathComponent(namespace, isDirectory: true))
    }

    static func local() -> StoreSession {
        StoreSession(modelVersion: modelVersion, namespace: "local-\(requestedRunName ?? "manual")", ready: true)
    }

    private static var requestedRunName: String? {
        // A launch argument isolates UI automation from the manual prototype store.
        let args = ProcessInfo.processInfo.arguments
        let run = args.firstIndex(of: "-LetsDoRun").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        return run?.range(of: "^[a-zA-Z0-9-]{1,70}$", options: .regularExpression) != nil ? run : nil
    }

    private static func validDistributionRunName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,69}\\z", options: .regularExpression) != nil
            && name.lowercased() != "manual"
    }

    private static func validDistributionNamespace(_ namespace: String) -> Bool {
        if namespace == "dist-manual" { return true }
        let prefix = "dist-"
        return namespace.hasPrefix(prefix) && validDistributionRunName(String(namespace.dropFirst(prefix.count)))
    }

    static func distributionRunName(arguments: [String]) throws -> String? {
        let markers = arguments.indices.dropFirst().filter { arguments[$0].hasPrefix("-LetsDoRun") }
        guard let index = markers.first else { return nil }
        guard markers.count == 1, arguments[index] == "-LetsDoRun", index + 1 < arguments.count,
              validDistributionRunName(arguments[index + 1]) else {
            throw AppError.invalid("-LetsDoRun 需要一个以字母或数字开头、最多 70 个字母数字或连字符的独立名称，不能使用保留名称 manual；没有使用默认任务库。")
        }
        return arguments[index + 1]
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
        let run = try distributionRunName(arguments: ProcessInfo.processInfo.arguments)
        let base = try baseURL()
        let previous = FileManager.default.fileExists(atPath: base.appendingPathComponent("session.json").path)
            ? try readPublished(at: base) : nil
        let namespace = try distributionNamespace(run: run, previous: previous)
        let blocked = StoreSession(modelVersion: modelVersion, namespace: namespace, ready: false)
        try publish(blocked)
        return blocked
    }

    // A cold Widget link has no launch arguments. Keep the last distribution
    // library even while extensions are blocked.
    static func distributionNamespace(run: String?, previous: StoreSession?) throws -> String {
        if let previous {
            guard (1...modelVersion).contains(previous.modelVersion),
                  validDistributionNamespace(previous.namespace) else {
                throw AppError.unavailable("桌面任务库记录不兼容，原库与草稿已保留。")
            }
        }
        guard let run else { return previous?.namespace ?? "dist-manual" }
        guard validDistributionRunName(run) else {
            throw AppError.invalid("无效的桌面测试库名称。")
        }
        return "dist-\(run)"
    }

    static func forMainApp(blockedSession: StoreSession?) throws -> StoreSession {
        if isLocalBuild { return local() }
        guard let blockedSession, !blockedSession.ready, blockedSession.modelVersion == modelVersion else {
            throw AppError.unavailable("桌面任务库尚未完成本次启动检查。")
        }
        let namespace = try distributionNamespace(run: nil, previous: blockedSession)
        return StoreSession(modelVersion: modelVersion, namespace: namespace, ready: true)
    }

    static func forExtension() throws -> StoreSession {
        guard !isLocalBuild else {
            throw AppError.unavailable("请使用桌面本机版添加系统小组件。")
        }
        let base = try baseURL()
        let session = try readPublished(at: base)
        guard session.ready, session.modelVersion == modelVersion else {
            throw AppError.unavailable("请先打开主应用完成存储与模型检查。")
        }
        guard try readPublished(at: base) == session else {
            throw AppError.unavailable("桌面任务库已切换，请刷新小组件；没有访问其他任务库。")
        }
        _ = try session.distributionDirectory(at: base)
        return session
    }
}
