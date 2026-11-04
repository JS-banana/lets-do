# AGENTS.md

## 协作

- 默认中文交流；修改前核对当前差异，保留其他协作者的改动。
- README 面向应用使用者，工程细节放到 [开发说明](docs/DEVELOPMENT.md)，签名与发版放到 [发布说明](docs/RELEASING.md)。
- 按实际代码、工程配置与运行证据描述功能。构建、XCTest、原生 GUI、系统 Widget 与跨设备同步分别验证，不能相互替代。
- 本地 shell 遵循使用者环境中已有的工具约定；GitHub Actions 直接使用 runner 自带工具。

## 验证

- 项目原生框架实现，无第三方包依赖；入口为 `Todo.xcodeproj`。
- `python3 scripts/check.py unit`：Mac XCTest。
- `python3 scripts/check.py build`：Local Mac、iPhone 模拟器／设备编译。
- `python3 scripts/check.py cloud-build`：CloudDevelopment 无签名编译，不代表云能力已可使用。
- `python3 scripts/check.py desktop-compile`：DesktopLocal App 与 Widget 无签名编译。
- `python3 scripts/package-mac.py`：签名、检查和打包 Mac 本机发行版，需要有效的团队签名。
- 日志与报告保存在被忽略的 `.build/`；不提交本机配置、凭据、数据库、原始设备标识或个人内容。

## 数据与系统接入

- Local、DesktopLocal 与 CloudDevelopment 的库互相隔离。自动运行使用独立 `-M0Run <字母数字或连字符>`，不要复用手工任务空间。
- 写入复用 `Shared/TaskStore.swift`；修改日期、存储、Intent 时检查共同规则与调用方。
- 主应用负责建库、迁移和云镜像；扩展只打开已核验的共享库，不建库、不迁移、不持有云镜像。
- 正文版本保持不可变，删除使用 tombstone；保留草稿及错误恢复能力。账户或模型检查失败时阻断危险写入，不删库重建或跨账户搬库。
- 不通过伪造 Team ID、移除权限验证或关闭系统保护来获得 Widget 共享能力。未配置有效签名时，只能证明编译，不能把无签名构建当完整发行包。
