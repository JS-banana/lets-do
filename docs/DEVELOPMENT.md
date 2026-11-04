# 开发说明

## 环境与运行

需要 macOS 和支持 Swift 6 的完整 Xcode。当前自动检查选择 Xcode 26.3；Mac 部署目标为14.0，iPhone为17.0。运行依赖 Apple 原生框架，没有需要安装的第三方包。

1. 克隆仓库，打开 `Todo.xcodeproj`。
2. 选择 `TodoM0Mac`、`My Mac`，保留 `Local` 配置，点击 Run。
3. 自动化运行在 scheme 的启动参数中添加 `-M0Run example-01`；每轮选择新的字母、数字或连字符名称。

Local 默认将任务放在用户 Application Support 下的 `TodoM0/Local/local-manual/`。实际位置在应用「设置 → 存储详情」查看。自动化的独立名称会生成不同的库，避免影响手工使用。

## 配置

| 配置 | 用途 | 数据与权限 |
|---|---|---|
| `Local` | 无云的本机开发与测试 | 独立任务库，不访问系统 Widget 共享库 |
| `DesktopLocal` | Mac 本机应用与系统 Widget | 同团队前缀 App Group，不连接 iCloud，需要有效团队签名 |
| `CloudDevelopment` | 双端云功能开发 | 隔离的 CloudKit Development 容器，需要实际注册的能力与签名；尚未完成真实双端验收 |

需要签名时，将 `Config/Signing.example.xcconfig` 复制为 `Config/Signing.local.xcconfig`，填写自己的团队及标识。该文件不入版本管理。DesktopLocal 的共享组使用实际 Team ID 前缀；不能通过随意填写 Team ID 或自签证书获得相同权限。

Mac 桌面 scheme 为 `TodoM0Desktop`，iPhone scheme 为 `TodoM0iPhone`。从源码自签 iPhone 本机版可以使用 Personal Team；免费配置有有效期与能力限制，不能等同于公开 iPhone 分发。CloudKit 使用设备系统 Apple 账户，不实现另一套账号密码。

## 检查

在仓库根目录运行：

```sh
python3 scripts/check.py unit
python3 scripts/check.py build
python3 scripts/check.py cloud-build
python3 scripts/check.py desktop-compile
```

已有签名配置时还可运行 `python3 scripts/check.py desktop-build`。完整命令、日志、源码散列及 XCTest 结果保存在 `.build/`，不随源码提交。无签名编译不代表 Widget 注册、App Group 共享、真实 iPhone 或云同步通过。

## 源码入口

| 路径 | 职责 |
|---|---|
| `App/` | 应用窗口、任务编辑、周历与月历 |
| `Shared/` | 日期规则、任务库、草稿、共享会话、Intent 与 Widget 布局 |
| `Widgets/` | WidgetKit 扩展入口 |
| `Tests/` | 日期、排布、书写、会话与存储检查 |
| `Config/` | 平台配置、权限与签名模板 |
| `scripts/` | 可重复的构建、测试及打包入口 |

任务写入集中在 `TaskStore`；正文追加不可变版本，删除使用 tombstone。主应用建库、迁移并持有云镜像，扩展只访问已确认的库。账户、模型或启动检查失败时保留原库和草稿，不删库重建、不跨账户自动搬运数据。

## 公开范围

此仓库从当前开发源码建立干净起点。原型阶段的内部参考截图、个人路径、设备记录、调试库、签名配置与完整本地验收档案不进入公开仓库。图标为项目生成资源；应用没有引入参考项目的代码或运行依赖。

CI 状态见 [GitHub Actions](https://github.com/JS-banana/lets-do/actions)，发行与签名设置见[发布说明](RELEASING.md)。
