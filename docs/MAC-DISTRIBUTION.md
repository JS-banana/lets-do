# Mac 分发、存储与验收

## 范围与配置

MacDistribution 包含主应用和今日、周、月三个 Widget。构建不需要付费开发者团队。分发应用使用 `com.panion.letsdo` 与 `letsdo`，Widget 使用 `com.panion.letsdo.widget`。主应用非沙盒，Widget 保留沙盒。[开发配置](DEVELOPMENT.md#配置与-scheme)

## 应用内更新的进程与权限

打包器把独立的 `Update.app` 放入主应用的 `Contents/Helpers`。只有助手链接 Sparkle。主应用通过私有管道发起检查，进程结束时管道关闭。助手只更新包含它的宿主应用。[应用内更新与验签](RELEASING.md#mac-应用内更新)

ad hoc 签名没有 Team ID，Hardened Runtime 默认的库校验会拒绝加载独立签名的 Sparkle。打包时保留 Sparkle 官方签名，只给助手设置库校验例外。macOS 14 的库加载约束将允许的第三方代码限定为固定发行包中两个架构的 Sparkle CDHash，打包器分别检查两个切片的签名约束。主应用和 Widget 沿用各自的权限。[打包脚本](../scripts/package-mac.py) · [Apple 库加载约束说明](https://developer.apple.com/videos/play/wwdc2023/10266/)

## 单库与共享门禁

分发任务库位于 Widget 自身 Application Support 下的 `LetsDo/MacDistribution/<命名空间>/`。Widget 使用系统提供的目录，非沙盒主应用按固定 Widget 身份定位同一目录。任务库目录或其直接父目录为符号链接时拒绝开库。命名空间选择与测试用户设置见[隔离运行](DEVELOPMENT.md#隔离运行)。[StoreSession](../Shared/StoreSession.swift)

主应用启动时先阻断扩展，关闭旧连接，打开目标库后才发布就绪会话。会话须通过命名空间和模型版本校验。旧时间线、旧命名空间或启动失败时，保留原库和草稿，拒绝向其他库写入。扩展读写遵循共享的[数据规则](DEVELOPMENT.md#数据规则)。[TaskStore](../Shared/TaskStore.swift)

macOS 14 起，容器访问与代码签名关联，非沙盒应用访问 Widget 容器可能需要授权。不同 ad hoc 构建即使 Bundle ID 和安装路径相同，也要实测覆盖安装后的访问结果。保留 Widget 沙盒和系统保护，容器拒绝时记录错误并验证恢复路径。[Apple 容器访问说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) · [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## 候选资产验收

按[发布说明](RELEASING.md#验收同一份候选)取得候选和 manifest，使用[隔离环境](DEVELOPMENT.md#隔离运行)中的合成任务验收。记录源码、资产散列、系统、硬件和实际覆盖。每版的结果与未覆盖项写在对应的 [Release 说明](https://github.com/JS-banana/lets-do/releases)。

| 项目 | 在同一候选上观察 |
|---|---|
| 安装与冷启 | 从 DMG 拖放安装，按[首次打开步骤](USAGE.md#安装与首次打开)启动，通过系统搜索找到应用。新建测试任务并重启，核对 UUID、安排和草稿。 |
| 系统放置与链接 | 从系统图库分别把今日、周、月组件放入通知中心和桌面。核对显示的任务、日期和快速记链接。两种放置位置分别记录。 |
| 完成与时间线 | 分别在主应用前台、关窗仍运行、进程完全退出时勾选并连点。核对 Intent 的进程、PID、动作 ID、提交和实际显示。重启主应用，按原任务 UUID 读回完成状态。 |
| 冷启与过期操作 | 验证快速记冷启能恢复草稿。已删除任务、旧时间线、切库、缺库及不兼容模型必须拒绝误写。 |
| 覆盖安装与权限 | 核对实际运行的应用和扩展版本、新时间线及同一容器的访问。单独记录出现授权提示、拒绝与恢复的结果。 |
| 支持范围 | 分开记录实测的系统、硬件和编译目标。没有条件执行的项目标明未验证。 |

完成后仅按本轮精确路径清理临时应用、Widget 登记和测试数据，保留其他应用与日常库。待复验项目见[当前验证边界](DEVELOPMENT.md#当前验证边界)。
