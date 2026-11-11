# AGENTS.md

## 协作与入口

- 默认中文交流；先检查当前差异与直接相关流程，保留其他协作者改动。同一时间只有一个编码子代理；只读审查可并行。
- 文档按最终用途整体整理：关键事实、约束、证据边界与下一步集中维护，入口只保留摘要和引用，不追加流水或重复补丁。
- [README](README.md) 面向使用者；环境、配置、源码与检查命令见[开发说明](docs/DEVELOPMENT.md)；候选构建和公开发行见[发布说明](docs/RELEASING.md)；Mac 存储、旧库升级与系统验收规则见 [Mac 分发说明](docs/MAC-DISTRIBUTION.md)。
- M0 范围、数据规则、双端必需矩阵与冻结门槛见 [M0 执行与验收契约](docs/M0-CONTRACT.md)；新证据摘要、待验条件与下一步集中更新契约的当前验证边界，原始材料留在 `.build/`，不在入口追加流水。
- 界面工作先读[界面与交互](docs/DEVELOPMENT.md#界面与交互)：任务内容优先，精简冗余操作，统一组件与间距，保留用户上下文、草稿保护和无障碍。
- 本地 shell 遵循使用者环境中已有的工具约定；GitHub Actions 使用 runner 自带工具。不提交本机签名配置、凭据、个人路径、设备标识、数据库或原始私有日志。

## 修改与验证

- 工程入口为 `Todo.xcodeproj`，使用原生框架，无第三方包依赖。修改日期、存储、Intent 时检查 Shared 的共同规则及调用方，按[检查与构建](docs/DEVELOPMENT.md#检查与构建)运行对应验证。
- Local、MacDistribution、DesktopLocal 与 CloudDevelopment 的用途、路径和权限保持区分；公开 Mac 包使用 MacDistribution，不能用 Local 编译代替分发配置验证。
- 自动运行使用新的隔离 `-M0Run` 名称，禁止使用手工库及 `manual` 的大小写变体。无效分发参数必须安全拒绝，不能落入默认库。
- 构建、XCTest、签名校验、原生 GUI、系统 Widget、iPhone 与云同步分别留证；不把刷新请求、同进程测试或编译通过记作系统运行通过。
- 报告和日志保存在被忽略的 `.build/`；检查期间源码变化时不能作为稳定版本验收。最终运行验收绑定同一候选资产与散列，公开时不得重建、重签或重传替代资产。

## 数据与系统边界

- 任务读写复用 `Shared/TaskStore.swift`；路径、角色及会话选择集中于 `Shared/StoreSession.swift`，旧 Local 升级集中于 `Shared/LocalLibraryUpgrade.swift`。不另建可写快照或多位置任务库。
- 主应用负责建库与迁移，仅云配置持有 CloudKit 镜像；Widget／Intent 只打开已核验的现有库，不建库、不迁移。保留会话、模型租约与写锁。
- 正文保留不可变版本及父关系，删除使用 tombstone；账户、模型、授权或启动检查失败时保留原库与草稿，不删库重建、不跨账户搬库、不静默回落空库。
- 旧库升级保留完整数据与草稿，原子交换是提交点；交换后不以备份覆盖新库写入。不要用不含物理记录身份和草稿的任务 JSON 恢复代替完整升级。
- MacDistribution 保留 Widget 沙盒，不使用 Apple 团队或 App Group。不得通过伪造 Team ID、移除权限验证、关闭系统保护或全局系统登记重置来获得共享或掩盖问题。
