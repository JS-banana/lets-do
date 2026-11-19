# 开发说明

## 环境与运行

使用 macOS 和支持 Swift 6 的完整 Xcode。打开 `Todo.xcodeproj`，选择 `LetsDo` 和 `My Mac` 运行。Mac 部署目标为 macOS 14，检查脚本记录实际使用的 Xcode 版本。常规编译使用系统框架，打包时另行下载并校验独立更新助手使用的固定版 Sparkle。

## 配置与 scheme

| 配置 | Mac scheme | 主应用 Bundle ID | URL scheme | 任务库 |
|---|---|---|---|---|
| `Local` | `LetsDo` | `com.panion.letsdo.dev` | `letsdo-dev` | 用户 Application Support 下的 `LetsDo/Local/` |
| `MacDistribution` | `LetsDoDistribution` | `com.panion.letsdo` | `letsdo` | 主应用与 Widget 共用分发库，见 [Mac 分发说明](MAC-DISTRIBUTION.md#单库与共享门禁) |

两个 scheme 的 Archive 都使用 `MacDistribution`。运行时，`LetsDo` 使用 `Local`，`LetsDoDistribution` 使用 `MacDistribution`。Test Action 使用 `Local`，通过 `LETSDO_UNIT_TEST_HOST=1` 跳过宿主自动开库，由测试创建临时 TaskStore。

## 隔离运行

手工运行 Local 时使用 `local-manual`，实际路径可在「设置 → 存储详情」查看。自动运行或迁移试验一律使用新的隔离库。例如在 scheme 启动参数中填写 `-LetsDoRun example-01`，下轮换一个名称。名称以 ASCII 字母或数字开头，最多 70 个字母、数字或连字符，避开 `manual` 的所有大小写写法。

分发配置将显式名称映射为 `dist-<名称>`。缺值、重复参数、非法或保留名称均拒绝启动。无参数冷启会沿用已核验的分发会话，只有没有记录时才使用 `dist-manual`。保存的会话只接受这个手工库名称的精确拼写。

隔离名只区分任务库。同身份的分发应用会切换系统 Widget 的当前会话，无参数重启仍会沿用它；系统提醒事项与 TCC 授权也按系统身份生效。日常应用或 Widget 正在使用时，在独立 macOS 测试用户中验收同一候选，使用合成任务和测试清单。

## 检查与构建

在仓库根目录按改动范围运行。

| 命令 | 覆盖范围 |
|---|---|
| `python3 scripts/check.py unit` | Mac Local XCTest |
| `python3 scripts/check.py build` | 本机架构的 Mac Local 编译 |
| `python3 scripts/check.py distribution-build` | MacDistribution 主应用与 Widget 的无签名通用编译 |

分发编译和打包结束时会注销本次构建路径的临时系统登记。最终签名包的构建和校验见[发布说明](RELEASING.md#本机打包与留证)。远端检查见 [GitHub Actions](https://github.com/JS-banana/lets-do/actions)。

## 源码入口

| 路径 | 职责 |
|---|---|
| `App/TodoApp.swift`、`App/AppModel.swift` | 应用启动、会话绑定和任务操作 |
| `App/MainView.swift`、`App/WeekView.swift`、`App/MonthView.swift` | 主窗口、导航和日历 |
| `App/TaskDetailView.swift`、`App/QuickCaptureView.swift` | 任务详情、完整新增与独立快速记录窗口 |
| `App/SettingsView.swift` | 存储与快捷键设置、备份面板和小组件预览入口 |
| `App/MacReminders*.swift` | 系统提醒事项读写、关联与操作界面 |
| `App/MacUpdates.swift`、`MacUpdater/` | 主应用的检查更新入口、运行 Sparkle 的独立助手 |
| `Shared/StoreSession.swift` | 配置、进程角色、路径、命名空间与共享会话 |
| `Shared/TaskStore.swift` | Core Data 读写、锁、正文版本、草稿与历史消费 |
| `Shared/Scheduling.swift`、`Shared/TodayTasks.swift` | 日期区间、今天和待办的分组规则 |
| `Shared/TaskIntents.swift`、`Widgets/` | Widget 完成动作、WidgetKit 扩展入口 |
| `Tests/`、`Config/`、`scripts/` | 工程检查用例、构建配置与权限、构建和发布脚本 |

## 数据规则

- **任务提交。** TaskStore 是唯一可写的任务数据源，各入口共享它，不另建可写快照或多位置副本。按业务 UUID 幂等创建任务，标题和计划在同一事务提交，有初始正文时一并保存文字和格式。编辑只改涉及的字段，本机提交后才反馈成功。完成动作设置目标状态，连点不会反转；需要按请求去重的调用另用动作 UUID。
- **正文版本。** 每次保存正文和格式都追加不可变版本，保留版本 UUID、父 ID 和所有分支。恢复旧文字也追加版本。只改标题时保留已有版本，逐字输入只写草稿。
- **删除与重复。** 删除写入 tombstone，只能显式恢复。相同任务 UUID 的物理记录按 `recordKey` 稳定选主，显示一项，写入更新全部副本。任一副本的 tombstone 都生效。同名任务各自保留。正文按版本 UUID 归并，同一版本的文字、格式或父关系冲突时保留原记录并报错。物理清理需要单独的迁移设计和数据安全验证。
- **计划。** 类型、起止和时区编码为一个 JSON 标量，读写都要校验。并发改期的结果须是一个完整有效的计划。日期采用半开区间，界面结束日包含当天。零点、跨周／年和夏令时使用共享日期规则。`week` 表示该周待安排，排到具体日期时更新原任务 UUID。新版本须能读取既有计划、草稿与备份，无法解码时保留原库。
- **草稿。** 按任务库原子保存任务 ID、草稿 ID、基线父版本、文字、格式和捕获计划。重启时可恢复，捕获复用草稿的业务 UUID，正文保存以草稿 ID 幂等追加。事务成功后才清理草稿，清理失败保留文件并按 UUID 核对。外部更新保留正在输入的草稿；关闭详情前核实落盘，失败时保留编辑器和错误。切库后禁止旧详情写入新库。
- **进程与模型。** 主应用负责建库和模型迁移，扩展只打开已核验的现有库并独立消费历史。保留共享会话、模型租约和写锁，绑定时间线与命名空间。旧时间线、缺库或模型不兼容时拒绝写入并提示打开主应用。模型版本随工程、导出和证据记录，启动或迁移失败保留原库和草稿。
- **读取异常。** 主应用与 Widget 按任务隔离显示。遇到字段缺失、正文版本冲突、父版本成环（包括跨任务的环）或计划无法解码时，略过受影响的任务并显示数量。正文缺任务 UUID 时按关系归属，无法归属时不计入任务。保留原记录。不可读任务对应的捕获草稿留在磁盘，不恢复到编辑器；指向该任务的待打开链接在任务可读后继续处理。会话或模型检查失败时整库拒绝访问，Widget 隐藏任务并提示打开应用。分发版启动时若只有不可读任务，也须阻断扩展。JSON 导出和提醒事项完成回写使用严格读取，遇异常即停止。
- **迁移与恢复。** 主应用从 Core Data V1 迁至 V2 时保留旧纯文本正文。从一致读取视图导出任务 JSON，不完整时拒绝导出。恢复验收使用空的隔离本地库，禁止覆盖已有任务或从扩展恢复。任务 JSON 保存业务任务和正文版本，不含物理记录身份、草稿或持久化历史。验证两个独立 TaskStore 访问同一隔离库、写锁争用失败无部分提交，以及扩展遇缺库或不兼容模型时保留文件。恢复操作见[使用指南](USAGE.md#备份与恢复)。
- **隐私。** 日志只记录动作与对象标识、进程、耗时和错误类别，省略标题、正文及账户原始标识。公开截图与导出使用合成隔离数据。工程不承诺端到端加密。

共享写入、进程门禁和完成操作分别见 [TaskStore](../Shared/TaskStore.swift)、[StoreSession](../Shared/StoreSession.swift) 和 [TaskIntents](../Shared/TaskIntents.swift)。

## 留证与日志

每次检查记录实际命令、退出状态、源码提交、逐文件和日志的 SHA256，以及包、系统、模型版本和隔离名称。源码在运行中变化时标记该次结果，重新运行后再作稳定版本验收。不同源码、配置或签名包分别记录。最终候选的资产身份和公开流程见[发布说明](RELEASING.md#验收同一份候选)。

构建、XCTest、签名、原生 GUI、系统 Widget 和系统提醒事项互操作分别报告。原生 GUI 要有实际操作、截图和数据读回，未运行就标「未验证」。工程没有 XCUITest 目标。Widget 要观察实际宿主、交互与时间线，双架构编译只说明能构建这两种架构。

报告、原始日志、`.xcresult`、合成截图与导出保存在被忽略的 `.build/`。交接时注明材料是否保留。保留失败记录，修复后补新证据。公开页只放脱敏摘要和覆盖边界，引用可访问的资料。

`events.jsonl` 格式 2 中，`actionID` 标识一次业务动作，`subjectID` 标识任务或正文版本，`eventID` 标识一行日志。事务作者含进程和动作 ID，Intent 成功时复用该动作 ID。历史格式 1 的 `actionID` 标识业务对象，应按格式版本解释。

## 当前验证边界

| 范围 | 当前候选仍需实测 |
|---|---|
| 原生窗口 | 搜索自动聚焦、侧栏高亮与键盘跨组、待办分组、详情收起保存、设置内的 JSON 文件面板、小组件预览及链接。核对标题日期识别、全局快速记录（含主窗口全关）、提醒事项导入入口和坏记录提示。 |
| 日历与编辑 | 周待安排拖到日期、月历溢出、深色模式、减少动态效果、辅助功能、输入法、窄于 840 pt 的窗口、多窗口、写盘失败与运行中切库。 |
| 系统 Widget | 同一候选上核对通知中心和桌面放置、链接、扩展冷启、Intent 落库与时间线。覆盖安装后确认实际执行的扩展版本和系统显示。[候选资产验收](MAC-DISTRIBUTION.md#候选资产验收) |
| 系统与存储 | macOS 14 与 Intel 的真实运行、容器拒绝授权及恢复、扩展在主应用迁移时启动、物理断电耐久性均待验。大数据量下的延迟须另测。 |
| 提醒事项 | 首次授权、撤销和 ad hoc 覆盖升级后的授权延续，以及系统清单变化到达主应用和 Widget 的时机，按[提醒事项验收步骤](MAC-REMINDERS.md#验收步骤)实测。 |

此前隔离运行检查过抽屉与网格的位置、按日／周新建、跨入口草稿、日历工具栏和侧栏。旧构建也有中号周组件的桌面观察。每次换候选都重新记录实际覆盖；已公开包的运行结果见对应[发行说明](https://github.com/JS-banana/lets-do/releases)。
