# 构建与发布

## 分发包与 CI

Mac 下载包使用 `MacDistribution`，包含主应用和原生今日、周、月 Widget，支持 macOS 14 及以上的 Apple 芯片与 Intel Mac。主应用非沙盒，Widget 保留沙盒；两者分别采用 ad hoc 完整性签名，无 Apple 开发者证书、私钥、团队或 App Group，任务库不启用 CloudKit 镜像。系统提醒事项的互操作与授权单独按[提醒事项方案](MAC-REMINDERS.md)验证。存储与升级约束见 [Mac 分发说明](MAC-DISTRIBUTION.md)。

应用未经过 Apple 公证。首次打开可能需要在「系统设置 → 隐私与安全性」中单独允许该应用；不要求使用者提供开发者账号或关闭系统全局保护。

[CI workflow](../.github/workflows/ci.yml) 在 `main` 推送、面向 `main` 的 Pull Request 和手动触发时运行，使用 GitHub 托管的 macOS 15 runner 与 Xcode 26.3，执行[开发说明](DEVELOPMENT.md#检查与构建)中的 XCTest、Local、CloudDevelopment、DesktopLocal 和 MacDistribution 编译。CI 仅有代码读取权限，同一分支的新运行可取消旧运行，摘要 artifact 保留七天。它不替代 GUI、Widget、升级或 Gatekeeper 验收。

## 生成候选草稿

[Release preview](../.github/workflows/release.yml) 自动生成待验收的草稿。公开发行在验收后由维护者触发。

1. 合入 `main` 后，等待该提交的推送 CI 全部通过。`Release preview` 以最高的 `vX.Y.Z` 标签为基准递增补丁版本及构建号，自动为主应用和 Widget 应用这两个值。例如 `v0.3.0`（构建 `5`）之后会生成 `v0.3.1`（构建 `6`）。
2. 打包校验通过后，流程给通过 CI 的源码提交打标签并上传 Release 草稿。标签附注保存构建号，同一提交重跑复用已分配的版本和构建号。创建新标签前会再检查 `main`，发现分支已推进时交给新提交的 CI 结果处理，运行摘要会说明跳过原因。
3. 在运行摘要打开草稿，记录源码提交和 manifest SHA256，下载候选开始验收。

日常 PR 无需改版本配置。需要指定更高的主版本或次版本时，在 [Base.xcconfig](../Config/Base.xcconfig) 设置 `MARKETING_VERSION`。自动流程优先使用高于现有标签的配置版本，构建号使用配置值与上个版本构建号加一中的较大值。Xcode 在打包时接收版本参数，源码提交和配置文件保留原样。

需要手动准备时，在 Actions 中从 `main` 运行 `Release preview`，填写已存在的 `tag`，保持 `publish_existing_draft=false`。手动创建的历史格式标签仍按源码配置中的版本和构建号打包。打包或上传失败时可重跑失败任务。构建产物超过七天保留期，或旧任务重跑时原计划版本已被另一提交占用，则重跑整个流程。已有草稿不完整、标签与候选不一致或资产校验失败时，流程停止并保留现有材料供排查。

流程核对版本、标签与 `main` 祖先关系，锁定源码提交，运行 XCTest，再构建通用安装包。打包器保留 Widget，由内到外分别签名，并严格核对主应用／Widget 的身份、版本、URL、模型与 Intent 元数据、双架构以及权限；拒绝团队证书、App Group、云权限、调试权限及调试动态库。

候选草稿必须恰好包含四份资产：

- `lets-do-<版本>-macos-universal.dmg`
- `lets-do-<版本>-macos-universal.zip`
- `release-manifest.json`
- `SHA256SUMS`

DMG 与 ZIP 携带同一份应用及 MIT LICENSE。manifest 记录源码提交、版本、构建号、源码散列、归档散列和包校验结果；它的运行验收字段明确只代表构建与打包检查。

同标签已有完整草稿时，`prepare` 校验并返回草稿里原有资产的 manifest SHA256。发行版已公开时直接返回链接。上传失败时仅尝试删除本次新建、尚未完成的草稿。若验收发现问题，修复后用新版本生成候选。

## 验收同一份候选

维护者从草稿下载全部四份资产，先在同一目录核对：

```sh
shasum -a 256 -c SHA256SUMS
shasum -a 256 release-manifest.json
```

记录 manifest 散列、标签和源码提交。安装并验证下载的候选，按 [Mac 分发验收规则](MAC-DISTRIBUTION.md#候选资产验收)核对打开、检索、小组件交互、主应用退出、冷启和旧 Local 数据升级。不要修改候选内的 Info、重新签名或另行打包后，把结果归到原资产。

草稿仅供有仓库权限的维护者验收。公开记录应说明实际系统、硬件、验证范围和未覆盖项，不上传个人任务库、设备标识或原始私有日志。

## 公开已验收的草稿

在 Actions 中手动运行 `Release preview`，选择 `main`：

| 输入 | 填写内容 |
|---|---|
| `tag` | 已验收候选的同一版本标签 |
| `publish_existing_draft` | `true` |
| `manifest_sha256` | 验收时记录的 `release-manifest.json` SHA256，64 位小写十六进制 |
| `make_latest` | 勾选后公开为正式 Release 并设为 Latest，默认公开为预发布版 |

发布器下载现有候选资产，重新核对源码、版本、构建号、manifest、归档散列及远端资产身份，确认 manifest 散列与输入一致后，直接公开同一个草稿。勾选 Latest 时，运行摘要会在 GitHub 确认 Latest 后给出链接。资产或标签发生变化、候选缺失或散列不符时停止。

发布流程串行运行，避免同时分配同一个版本。只有上传草稿和公开发行的任务获得 `contents: write`，使用 GitHub 自带的 `GITHUB_TOKEN`。自动创建标签后在同一轮运行上传草稿。

## 本机打包与留证

需要 macOS 和完整 Xcode，无需签名配置：

```sh
python3 scripts/package-mac.py
```

默认输出到独立 `.build/packages/` 工作目录；也可使用 `--output-dir` 指定空的资产目录，或用 `--output` 指定 DMG 路径。输出已存在时拒绝覆盖，完整选项见 `python3 scripts/package-mac.py --help`。

打包不会安装或运行应用。Xcode 可能登记临时构建产物，脚本会精确注销本次主应用和 Widget 的构建路径；清理失败使打包失败，不做全局系统登记重置。报告、完整日志与发布诊断只保留在被忽略的 `.build/`，不作为下载资产上传。

本机包用于开发验证。正式候选由已校验标签的干净提交构建；本机检查、隔离安装证据与正式候选验收必须分别记录。
