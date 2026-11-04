<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/mac-128@2x.png" width="96" alt="Let’s Do 图标">
  <h1>Let’s Do</h1>
  <p>先记下来，再安排到某一天。</p>
  <p>
    <a href="https://github.com/JS-banana/lets-do/releases">下载与发行版</a> ·
    <a href="#使用">使用</a> ·
    <a href="docs/DEVELOPMENT.md">从源码运行</a>
  </p>
</div>

Let’s Do 是一款原生个人任务工具。把零散想法放进收集箱，用周历和月历安排事情。

目前处于早期开发阶段，以 Mac 本机使用为主；iPhone 源码已包含，iCloud 跨设备同步仍在验证中。

## 安装

从 [GitHub Releases](https://github.com/JS-banana/lets-do/releases) 下载 Mac 预览版。安装包由 GitHub Actions 构建，不需要维护者提供证书或私钥。

Mac 安装包面向 **macOS 14 及以上**，同时支持 Apple 芯片与 Intel：

1. 下载发行版中的 `.dmg`，打开后把 `Let's Do.app` 拖到「Applications／应用程序」。
2. 推出安装磁盘，从「应用程序」打开 Let’s Do；之后可搜索 `Let` 查找。
3. 如系统提示无法验证开发者，先尝试打开一次，再前往「系统设置 → 隐私与安全性 → 仍要打开」。参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

使用者不需要 Xcode，也不需要购买开发者会员。当前计划发布的预览包未公证，数据保存在本机。

## 使用

- **随手记**：在底部输入标题，按回车添加；有需要时再补备注和日期。
- **先收集，再安排**：没有日期的想法留在收集箱；任务可以安排到某一天、某一周或连续多天。
- **用日历看全局**：切换周历、月历，点击日期查看任务，拖动即可改期。
- **找到与回顾**：搜索标题，直接完成任务；详情保留正文历史，删除的任务进入回收站。

`⌘N` 打开详细新建，`⌘↩` 提交；`⌘⇧N` 新建主窗口。

在「设置 → 数据与诊断」中可以导出 JSON 备份。恢复仅支持空的本地库；早期版本请保留独立备份。

## 当前范围

Mac 下载版使用本机任务库，不连接 iCloud，也不包含系统桌面小组件。项目保留 iPhone、CloudKit 和 Widget 的开发源码；它们的权限配置与真实设备运行分别验证，不能把源码或编译通过当作下载版已提供这些能力。

无需注册应用账号。涉及开发签名、存储位置与隔离测试的说明见[开发文档](docs/DEVELOPMENT.md)；CI 和维护者发版流程见[发布文档](docs/RELEASING.md)。

## 开发

使用支持 Swift 6 的 Xcode 打开 `Todo.xcodeproj`，选择 `TodoM0Mac` 和 `My Mac`，使用默认 `Local` 配置运行。工程使用 SwiftUI、AppKit、Core Data、WidgetKit 与 App Intents，目前没有第三方包依赖。

```sh
python3 scripts/check.py unit
python3 scripts/check.py build
```

遇到问题可[提交 Issue](https://github.com/JS-banana/lets-do/issues)，附上系统版本、应用版本、复现步骤；请勿上传个人任务库或签名凭据。

## 许可

[MIT](LICENSE) © JS-banana
