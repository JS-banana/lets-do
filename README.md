<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/mac-128@2x.png" width="96" alt="Let’s Do 图标">
  <h1>Let’s Do</h1>
  <p>先记下来，再安排到某一天。</p>
  <p>
    <a href="https://github.com/JS-banana/lets-do/releases/latest"><strong>下载 Mac 预览版</strong></a> ·
    <a href="docs/USAGE.md">使用指南</a> ·
    <a href="https://github.com/JS-banana/lets-do/issues">反馈问题</a>
  </p>
  <p><sub>macOS 14 及以上 · Apple 芯片与 Intel · 免费开源</sub></p>
</div>

Let’s Do 是一款原生 Mac 任务应用，用日历安排待办，也能借助 Apple「提醒事项」在手机上接着处理。

![在 Let’s Do 中记录任务、选择日期，再到周历查看安排](docs/images/readme/capture-to-calendar.gif)

<p align="center"><sub>v0.3.1 · 真实界面，使用示例任务演示</sub></p>

<!-- 动图使用与 v0.3.1 一致的应用源码、隔离的 Local 构建与示例任务，由真实操作关键帧组成；更新界面时一并更新。 -->

想读的书、周末要买的东西，写个标题就能记下。日期还没想好，可以先留在待办，或放进某一周的「待安排」；确定后再安排到具体日期，计划有变就拖动改期。周历看眼前几天，月历看更远的安排。

每天从「今天」开始，看看当天要做什么，也接着处理此前没做完的事。还可以把任务和日历放进桌面小组件，随时查看、勾选完成。

## 手机随手记，回到 Mac 接着安排

出门时想起一件事，直接记进 iPhone 自带的「提醒事项」。借助 iCloud 提醒事项同步，回到 Mac 后就能在 Let’s Do 中选择导入。也可以把 Mac 上的某条任务发送到提醒事项，在手机勾选完成，Let’s Do 读取到变化后会完成对应任务。无需另装手机应用或注册新账号，[设置方法与同步范围](docs/USAGE.md#与手机上的提醒事项配合)见使用指南。

## 下载与安装

从 [GitHub Releases](https://github.com/JS-banana/lets-do/releases/latest) 下载 `.dmg`，打开后把 **Let’s Do.app** 拖进「应用程序」，再从那里启动。

当前预览版尚未经过 Apple 公证。首次打开若被系统拦截，可在「系统设置 → 隐私与安全性」选择「仍要打开」，详见[安装帮助](docs/USAGE.md#安装或使用遇到问题)。任务库保存在本机，重要内容建议定期[导出备份](docs/USAGE.md#备份与恢复)。独立的 iPhone 客户端仍在开发中。

## 一起改进

用起来有不顺手的地方，欢迎[提一个 Issue](https://github.com/JS-banana/lets-do/issues)，聊聊你想做什么、遇到了什么。想从源码运行或参与开发，可以从[开发说明](docs/DEVELOPMENT.md)开始。

[产品设计](docs/PRODUCT-DESIGN.md) · [发布说明](docs/RELEASING.md) · [MIT License](LICENSE)
