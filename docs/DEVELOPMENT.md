# 开发说明

## 环境与运行

需要 macOS 和支持 Swift 6 的完整 Xcode。检查脚本使用当前选定的 Xcode，并在报告记录实际版本；Mac 部署目标为 macOS 14，iPhone 为 iOS 17。工程仅使用 Apple 原生框架，无需安装第三方包。

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

Mac 的 XCTest 宿主通过测试 scheme 的 `M0_UNIT_TEST_HOST=1` 跳过自动开库；测试自行创建临时 TaskStore，不打开手工库。

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

## 界面与交互

界面围绕记录、查看、安排和完成任务组织，优先采用熟悉的原生交互。

- **内容优先**：先展示任务文字；省去重复品牌、可由上下文判断的字段标签和常态说明，保留辅助功能标签。
- **高频路径直接**：快速输入使用合理默认值；日期、备注和进阶安排按需展开，每个常驻控件都应服务当前操作。
- **视觉一致**：相关控件共用组件、字号与间距规则；以对齐、紧凑行距和必要的分组留白形成层级，保留长标题换行。
- **上下文连续**：打开详情保留已展开导航；窗口适配随空间约束变化，窄窗保持可见返回。多个新增入口共用草稿，并保留各自明确的日期语义。
- **状态就近反馈**：正常状态保持安静；实际修改时提供明确保存，冲突和失败时显示必要说明与恢复入口。简洁不能改变正文提交语义或削减草稿、版本和回收站保护。
- **按真实界面验证**：同时查看清单、详情和弹层，操作关闭、返回和恢复路径；收紧视觉尺寸时保留各平台可点击范围与键盘、辅助功能支持。

以下为现行源码的稳定交互约定，不表示下载版本已具备或已验收所有行为。主要实现见 [PrototypeView](../App/PrototypeView.swift)、[TaskWritingEditor](../App/TaskWritingEditor.swift) 和 [ScheduleFields](../App/ScheduleFields.swift)。颜色、字号与间距以 [AppStyle](../Shared/AppStyle.swift) 及组件的现行定义为准，不另复制一套视觉 token。

### 捕获与日期

- Mac 底部回车保存共享草稿。空白输入在今天页预设今天，在日历预设选中日，在收集箱和全部任务预设无日期。用户已选安排及已输入草稿跨入口保留。日历空白新建明确采用所点日期。
- 底部输入、嵌入详细新增与独立快速记复用 [CaptureDraft](../App/CaptureDraft.swift) 的标题、正文、格式、业务 UUID 和保存事务；同一时刻只由一个完整编辑器拥有草稿。只有事务成功后才清理草稿并轮换 UUID；失败保留输入，重试不得重复创建任务。
- 共享日期弹层区分宿主：已有任务的快捷日期、移除日期和单日点选立即应用到原 UUID；新增只修改捕获草稿，等明确添加才创建任务。周归属和跨多天先修改局部表单，显式“应用”才交给宿主；折叠进阶选项不应丢掉应用入口。浏览月份不写任务，返回／Escape／外部关闭放弃未应用的局部安排，不提交正文；失败保留弹层和重试信息。
- 旧 `timed` 任务未明确改期时保留原时段，正文编辑不改变安排；明确选择新日期后才按天转换。周归属是待安排队列，不占七天日程；日期与 `+N` 在当前周／月内展开当天完整任务，旧议程链接只作兼容入口。

### 详情与草稿

- 详情从实际文字开始，不放重复标题占位和顶部操作簇；日期为紧凑共享弹层入口，删除置底部，版本与完成放更多菜单。清单保留直接完成；正常状态安静，仅实际本机修改时显示保存，正文仍显式提交为不可变版本。
- 打开详情保留已展开侧栏，窄窗保留返回。外部点击／返回／Escape 收起前先结束原生输入并核实本机草稿落盘，失败保留详情与错误；输入法组字和日期／历史弹层优先处理自己的关闭，不连带关闭详情。
- 本机编辑相对其原始文字与父版本判断，远端更新不伪装成本机编辑、不覆盖正在输入的草稿。草稿与正文保存核对原 store 实例，切库后旧详情回调不得写入新库；冲突分支、其他本机草稿和回收站恢复入口不能因精简而隐藏。

### 日历与 Widget

- [TodayTasks](../Shared/TodayTasks.swift) 供两端今天页和桌面摘要共用。按显示时区的半开日期区间判断，结束日已过且未完成的任务列入此前未完成；整周结束后仍未安排到具体日的周任务也会出现。无日期只计入收集箱，不改写计划。小号优先显示最近的一条此前任务，中号在当前与此前均有任务时各保留一行。数量链接打开真实清单，日期格仍按原计划绘制。
- iPhone 打开今天页，周历按「七天切换＋选中日任务」纵向显示；Mac 保留七列周板。
- 周列保留最小可读宽度，空间不足横向滚动，不靠缩字或压缩七列塞入窗口；分列线贯穿日期头、跨日区与任务区。月历跨周条、半开区间和每天的溢出数复用共享日期／排布规则，点击定位原任务，拖动保持 UUID 与原跨度。
- 中号周 Widget 按当前时区的周一至周日投影未完成任务，按 UUID 去重：今天最多两条，其余预算优先后续日期，再容纳本周待定日；不以收集箱或其他周填满。`+N` 只属于所在日期／分组，为该组总数减可见数；日期与溢出进入当天完整任务，不把别日数量合并过来。
- 摘要中的跨日任务只归一次：覆盖今天则归今天，否则归本周首次涉及的未来日；完整日任务仍包含实际覆盖该日的延续安排，零点结束不多算一天。已过期区间中的未完成任务使用“此前未完成”入口，未来日期中未展示的任务保留“其他”入口；其他计数不重复计算已由某日 `+N` 承接的任务。规则见 [WeekTaskOverview](../Shared/WeekTaskOverview.swift)。
- 正常空、今天／整周已完成与读取／身份检查失败分开显示，失败不能假装空任务。固定 family 不靠缩字挤入全部内容，完整标题保留辅助功能与原任务入口；本机完成／打开应用后同步提示不能删。App 预览、系统宿主和真实跨端传播分别留证，见 [M0 契约](M0-CONTRACT.md)。

## 公开资料边界

公开仓库保存源码和可维护的使用、开发及发布说明。本机签名配置、个人路径、设备标识、任务库、原始运行日志及原型参考截图不进入仓库。图标为项目生成资源，应用没有引入参考项目的代码或运行依赖。

CI 运行见 [GitHub Actions](https://github.com/JS-banana/lets-do/actions)。M0 必需矩阵、证据边界与待验项集中于 [M0 契约](M0-CONTRACT.md)；Mac 系统验收与候选资产要求以 [Mac 分发说明](MAC-DISTRIBUTION.md)为准，不在本页维护通过数量或逐次运行流水。
