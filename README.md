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

Let’s Do 是一款原生个人任务工具。随手记下想法，在待办里整理，再用周历和月历安排事情。

目前处于早期开发阶段，以 Mac 本机使用为主；iPhone 源码已包含，iCloud 跨设备同步仍在验证中。

## 安装

从 [GitHub Releases](https://github.com/JS-banana/lets-do/releases) 下载 Mac 预览版。

Mac 安装包面向 **macOS 14 及以上**，同时支持 Apple 芯片与 Intel：

1. 下载发行版中的 `.dmg`，打开后把 `Let's Do.app` 拖到「Applications／应用程序」。
2. 推出安装磁盘，从「应用程序」打开 Let’s Do；之后可搜索 `Let` 查找。
3. 如系统提示无法验证开发者，先尝试打开一次，再前往「系统设置 → 隐私与安全性 → 仍要打开」。参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

使用者不需要 Xcode，也不需要购买开发者会员。当前预览包未公证，数据保存在本机。

## 使用

以下操作以当前源码为准。

- **随手记**：在底部输入标题，按回车添加；有需要时再补备注和日期。
- **先记下来，再安排**：「待办」汇总所有未完成任务，包括还没安排的事项。任务可以安排到某一天、某一周或连续多天。也可以先点「放入本周待安排」，再选具体日期。
- **用日历看全局**：切换周历、月历，点击日期查看任务，拖动即可改期。
- **找到与回顾**：搜索标题，直接完成任务；详情保留正文历史，删除的任务进入回收站。

`⌘N` 打开详细新建，`⌘↩` 提交；`⌘⇧N` 新建主窗口。

在「设置 → 数据与诊断」中可以导出 JSON 备份。恢复仅支持空的本地库；早期版本请保留独立备份。

### Mac 预览版 v0.3.0

Mac 可以从选定的系统提醒事项清单导入待办。两端开启 iCloud 提醒事项后，可先在 iPhone 自带的提醒事项里记录，再到 Mac 选择要安排的事项。在 Mac 任务详情的「更多」中，也可以把指定任务发送到手机清单。在手机勾选后，Mac 应用会在读取到变化时完成原任务。需要 v0.3.0 或更新的 Mac 版本。[操作与验收](docs/MAC-REMINDERS.md)

## 桌面小组件

小组件需要 **v0.2.0 或更新版本**；v0.1.1 只包含主应用。各版本的可用下载以 [Releases](https://github.com/JS-banana/lets-do/releases) 为准。

1. 安装后先打开一次 Let’s Do，完成任务库初始化。
2. 在 Mac 桌面右键，选择「编辑小组件」，搜索 Let’s Do。
3. 添加「今天的任务」「本周计划」或「月历总览」，选择适合桌面的尺寸。

点击任务旁的圆圈可标记完成；点击任务标题或日期可打开应用中的对应内容。「快速记」会打开应用的记录窗口，供你输入并保存。

当前源码中的「今天的任务」会显示今天安排的事和此前仍未完成的事。小号优先显示一条此前未完成的任务，中号在两组都有任务时各显示一条。点击数量会打开应用内的对应清单，底部「待办」可查看所有未完成任务。

中号「本周计划」按原计划日期分组，点击日期或 `+N` 打开当天清单。只定了周的事项归入「本周待安排」，跨周仍未完成的事项可从「往周未完成」查看。

## 当前范围

Mac 下载版使用本机任务库，不连接 iCloud，无需注册应用账号。iPhone 与跨设备同步的源码仍在开发验证中。

小组件与旧版本数据升级的实现和验收范围见 [Mac 分发说明](docs/MAC-DISTRIBUTION.md)。

## 开发

工程使用 SwiftUI、AppKit、Core Data、WidgetKit 与 App Intents，没有第三方包依赖。从源码运行与检查见[开发说明](docs/DEVELOPMENT.md)，CI 和维护者发版见[发布说明](docs/RELEASING.md)。

遇到问题可[提交 Issue](https://github.com/JS-banana/lets-do/issues)，附上系统版本、应用版本、复现步骤；请勿上传个人任务库或签名凭据。

## 许可

[MIT](LICENSE) © JS-banana
