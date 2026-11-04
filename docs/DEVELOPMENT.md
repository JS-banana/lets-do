# 开发说明

## 环境与运行

需要 macOS 和支持 Swift 6 的完整 Xcode。自动检查固定使用 Xcode 26.3；Mac 部署目标为 macOS 14，iPhone 为 iOS 17。工程仅使用 Apple 原生框架，无需安装第三方包。

1. 克隆仓库，打开 `Todo.xcodeproj`。
2. 选择 `TodoM0Mac`、`My Mac`，使用默认 `Local` 配置运行主应用。
3. 自动化运行在 scheme 的启动参数中添加 `-M0Run example-01`，每轮使用新的隔离名称，禁止使用 `manual` 或其大小写变体。

Local 的手工库位于用户 Application Support 下的 `TodoM0/Local/local-manual/`。实际路径可在应用「设置 → 存储详情」查看。不要用个人任务库进行自动化或迁移试验。

## 配置与 scheme

| 配置 | Mac scheme | 数据与权限 |
|---|---|---|
| `Local` | `TodoM0Mac` | 独立本机主应用；不连接 iCloud，不访问系统 Widget 共享库 |
| `MacDistribution` | `TodoM0Distribution` | 公开 Mac 包的主应用与 Widget；无 Apple 证书、团队或 App Group，使用 Widget 自身容器中的单一本机库 |
| `DesktopLocal` | `TodoM0Desktop` | 团队签名的 Mac 主应用与 Widget；使用同团队 App Group，不连接 iCloud |
| `CloudDevelopment` | `TodoM0Mac` | 隔离的 CloudKit Development 库；需要实际注册的团队、容器与权限 |

iPhone 使用 `TodoM0iPhone`。`TodoM0Distribution` 的运行和归档使用 `MacDistribution`，Test Action 使用 `Local`；单元测试通过不代表分发配置或系统容器权限已经通过运行验收。

MacDistribution 主应用保留非沙盒运行方式，Widget 保留沙盒。其命名空间、容器访问、旧 Local 升级与真实验收规则集中在 [Mac 分发说明](MAC-DISTRIBUTION.md)。自动运行名称必须以字母或数字开头，最多 70 个字母、数字或连字符；分发配置会拒绝缺值、重复参数、非法名称及保留名称，不回落手工库。

需要开发团队能力时，将 [Signing.example.xcconfig](../Config/Signing.example.xcconfig) 复制为 `Config/Signing.local.xcconfig`，填写自己的团队及已注册标识；本机文件不入库。这是 DesktopLocal／CloudDevelopment 的设置，不是构建 MacDistribution 的前提。App Group 权限不能通过随机 Team ID 或自签名替代。

从源码运行 iPhone 可按 Xcode 支持的 Personal Team 条件配置；免费配置的有效期与能力限制不等同于公开 iPhone 分发。CloudKit 使用设备系统 Apple 账户，真实 iPhone 与跨设备同步单独验收。

## 检查与构建

在仓库根目录按改动范围运行：

| 命令 | 覆盖范围 |
|---|---|
| `python3 scripts/check.py unit` | Mac Local XCTest |
| `python3 scripts/check.py build` | Local Mac、iPhone 模拟器及设备编译 |
| `python3 scripts/check.py distribution-build` | MacDistribution 主应用与 Widget 的无签名通用编译 |
| `python3 scripts/check.py desktop-compile` | DesktopLocal 主应用与 Widget 无签名编译 |
| `python3 scripts/check.py cloud-build` | CloudDevelopment 无签名编译 |

已配置有效团队签名时，可另运行 `python3 scripts/check.py desktop-build`。打包下载资产使用 `python3 scripts/package-mac.py`，具体校验与发布步骤见[发布说明](RELEASING.md)。

检查报告、命令、源码散列、完整日志与 XCTest 结果保存在被忽略的 `.build/`。源码在检查期间变化时，该次结果不能作为稳定版本的验收证据。分发编译和打包会注销本次构建路径的临时系统登记，不安装或启动应用。

编译、签名校验、原生 GUI、真实系统 Widget、iPhone 和云同步分别验证。调用 Widget 刷新接口不等于系统已经刷新；双架构编译也不等于已在两种硬件上运行。

## 源码入口

| 路径 | 职责 |
|---|---|
| `App/` | 应用窗口、任务编辑、周历、月历与启动协调 |
| `Shared/StoreSession.swift` | 配置、进程角色、路径、命名空间及共享会话门禁 |
| `Shared/LocalLibraryUpgrade.swift` | MacDistribution 的旧 Local 库升级与中断恢复 |
| `Shared/TaskStore.swift` | Core Data 读写、锁、正文版本、草稿与历史消费 |
| `Shared/TaskIntents.swift` | Widget 的任务完成动作 |
| `Widgets/` | WidgetKit 扩展入口 |
| `Tests/` | 日期、排布、书写、会话、升级与存储检查 |
| `Config/` | 平台配置、权限与签名模板 |
| `scripts/` | 构建、测试、打包及发布入口 |

任务写入复用 TaskStore；正文追加不可变版本，删除使用 tombstone。主应用负责建库与迁移，仅云配置持有 CloudKit 镜像；扩展只访问已核验的库。账户、模型或启动检查失败时保留原库与草稿，不删库重建，不跨账户自动搬运数据。

## 公开资料边界

公开仓库保存源码和可维护的使用、开发及发布说明。本机签名配置、个人路径、设备标识、任务库、原始运行日志及原型参考截图不进入仓库。图标为项目生成资源，应用没有引入参考项目的代码或运行依赖。

CI 运行见 [GitHub Actions](https://github.com/JS-banana/lets-do/actions)。系统验收范围与候选资产的要求以 [Mac 分发说明](MAC-DISTRIBUTION.md)为准，不在本页维护通过数量或逐次运行流水。
