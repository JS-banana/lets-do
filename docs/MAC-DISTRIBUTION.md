# Mac 分发、存储与验收

## 范围与配置

v0.2.0 的 MacDistribution 包复用现有 Mac App、Widget targets 和 Core Data 模型，包含「今天的任务」「本周计划」「月历总览」。完成按钮提交明确的完成状态；任务、日期和「快速记」链接打开主应用相应入口。

公开主应用身份为 `com.panion.todo.m0.mac`，Widget 为对应的 `.widget`，URL scheme 为 `todom0`。MacDistribution 使用独立编译条件，主应用非沙盒，Widget 保留沙盒。Local 与 MacDistribution 的库路径和权限见[开发配置](DEVELOPMENT.md#配置与-scheme)。

## 应用内更新的进程与权限

打包器把独立的 `Update.app` 放入主应用的 `Contents/Helpers`。只有这个助手链接 Sparkle。主应用通过随进程结束而关闭的私有管道发起检查，助手只更新包含它的宿主应用。更新与验签流程见[发布说明](RELEASING.md#mac-应用内更新)。

ad hoc 签名没有 Team ID，Hardened Runtime 的默认库校验会拒绝加载独立签名的 Sparkle。打包时保留 Sparkle 官方框架的原签名，只给助手设置库校验例外，并用 macOS 14 的 library load constraint 将允许的第三方代码限定为固定发行包中两种架构的 Sparkle CDHash。打包器检查两个切片签名中的约束，主应用与 Widget 沿用各自的原权限。实现见[打包脚本](../scripts/package-mac.py)和 [Apple 的库加载约束说明](https://developer.apple.com/videos/play/wwdc2023/10266/)。

## 单库与共享门禁

唯一可修改的任务库位于 **Widget 自身 Application Support** 下的 `TodoM0/MacDistribution/<命名空间>/`。Widget 使用系统提供的自身目录；非沙盒主应用按固定 Widget 身份定位同一目录。角色、身份字段、路径及命名空间校验集中在 [StoreSession](../Shared/StoreSession.swift)，不维护多位置副本或另一份可写快照。当前任务库目录或其直接父目录是符号链接时，拒绝开库。

显式传入 `-M0Run` 时使用 `dist-<名称>`，`manual` 的任意大小写写法均会被拒绝。无参数冷启沿用已核验的会话，没有会话记录时使用 `dist-manual`。已保存的手工库会话也只接受 `dist-manual`，遇到 `dist-MANUAL` 等大小写变体时拒绝开库。

[TaskStore](../Shared/TaskStore.swift) 统一处理主应用、Widget 和 Intent 的 Core Data 操作。主应用负责建库和模型迁移，启动时先阻断扩展，关闭旧连接，打开目标库，再发布就绪会话。扩展只访问已核验的现有库，不建库、不迁移。

共享会话限制命名空间和就绪状态；模型租约保护打开的模型，写锁串行化修改。旧时间线、已切换空间或启动失败不能绕过门禁写入其他库。启动时如发现旧分发命名空间的会话记录，应用会拒绝开库并保留原库与草稿。正文使用不可变版本与父关系，删除使用 tombstone；完成动作设置目标状态，重复完成不会反转状态，但不等于请求去重。

macOS 的容器权限仍由系统决定。[Apple 的容器访问说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)指出，macOS 14 起容器访问与代码签名关联，非沙盒应用访问其他容器也可能需要授权；[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)解释了签名要求。同一 Bundle ID 或相同路径不能替代两次不同 ad hoc 构建的实际访问验证，不通过关闭系统保护或修改 Widget 沙盒绕过授权。

## 候选资产验收

已公开的 [v0.2.0](https://github.com/JS-banana/lets-do/releases/tag/v0.2.0) 与验收后的 CI 候选为同一份资产，已在 **macOS 15.6.1、Apple 芯片 Mac** 完成核心系统运行验收。对应源码为 `c84db01`，`release-manifest.json` 的 SHA256 为 `bc8ae2e6c406a09d453a107e050b38be812461e1e51b887758234bf1fdf70977`。验证使用独立测试副本，应用内容和签名未修改，DMG 与 ZIP 中的应用文件一致。

实际覆盖：

- 在系统图库添加今日、周、月组件，并于**通知中心**显示真实隔离任务；验证任务链接与日期日历链接。
- 区分关窗仍运行与主应用完全退出；退出后由已安装扩展完成任务，快速记冷启恢复待保存草稿。
- 将未经修改的公开 v0.1.1 的同名隔离任务库迁入该 CI 候选，保留任务 UUID、草稿、源 alias 和备份。相对先前本地构建，主应用和 Widget 的代码身份均改变，新进程仍能访问同一容器。

早期独立隔离身份的 A／B 桌面放置与覆盖升级，以及本地候选的旧进程锁冲突／同进程重试、临时 SQLite 中断恢复，分别保留独立证据。**本次 CI 候选的系统交互在通知中心完成，未验证该候选的桌面放置**，不把早期 A／B 桌面结果移作同一资产的通过项。

| 未覆盖范围 | 边界 |
|---|---|
| 用户日常安装 | 「应用程序」拖放、首次浏览器下载后的 Gatekeeper 授权、系统搜索界面由用户实际操作；本轮只核对独立副本的包元数据和 Spotlight 索引 |
| 其他系统与硬件 | macOS 14 和 Intel 只有编译检查，没有运行验收 |
| 容器拒绝授权 | 本轮没有出现授权提示，未验证拒绝与后续恢复 |
| 其他验收 | 完整视觉／辅助功能／输入法矩阵及物理断电耐久性未测 |

公开按[发布说明](RELEASING.md)重新核对已验收 manifest 和既有草稿资产，不重建、重签或替换资产。后续版本须重新记录实际覆盖与未覆盖范围，不自动继承本次结果；刷新接口调用也不能代替真实时间线观察。

测试使用隔离数据，临时应用、Widget 登记和数据须按本轮精确路径清理，不重置全局系统登记或触碰其他应用。`-M0Run` 只隔离任务库；同身份的分发包仍会切换系统 Widget 的当前会话，无参数重启会沿用该会话，不能当作恢复日常库的步骤。日常应用或 Widget 正在使用时，应改用独立 macOS 测试用户验证同一候选。系统提醒事项与 TCC 授权也不由 `-M0Run` 隔离。公开文档不保存私有路径、测试任务标识、通过计数或逐次运行流水。
