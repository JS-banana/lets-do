# 构建与发布

## 分发包与 CI

Mac 下载包使用 `MacDistribution`，为 macOS 14 及以上的 Apple 芯片和 Intel Mac 构建。主应用与 Widget 分别采用 ad hoc 完整性签名。分发身份及容器权限见 [Mac 分发说明](MAC-DISTRIBUTION.md)，用户安装步骤见[使用指南](USAGE.md#安装与首次打开)。

推送到 `main`、向 `main` 提 PR 或手动触发时，CI 在 GitHub 托管的 macOS 15 runner 上使用 Xcode 26.3，运行 Local XCTest，打包并校验 MacDistribution 通用包，测试更新清单。CI 只有代码读取权限，同一分支的新运行可取消旧运行，摘要 artifact 保留七天。[CI 工作流](../.github/workflows/ci.yml) · [检查与构建](DEVELOPMENT.md#检查与构建)

## 生成候选草稿

Release preview 自动生成待验收的草稿，公开发行由维护者在验收后触发。[发布工作流](../.github/workflows/release.yml)

1. 合入 `main` 后，等待该提交的推送 CI 全部通过。`Release preview` 以最高的 `vX.Y.Z` 标签为基准递增补丁版本及构建号，自动为主应用和 Widget 应用这两个值。例如 `v0.3.0`（构建 `5`）之后会生成 `v0.3.1`（构建 `6`）。
2. 打包校验通过后，流程给通过 CI 的源码提交打标签并上传 Release 草稿。标签附注保存构建号，同一提交重跑复用已分配的版本和构建号。创建新标签前会再检查 `main`，发现分支已推进时交给新提交的 CI 结果处理，运行摘要会说明跳过原因。
3. 在运行摘要打开草稿，记录源码提交和 manifest SHA256，下载候选开始验收。

日常 PR 无需改版本配置。需要指定更高的主版本或次版本时，在基础配置中设置 `MARKETING_VERSION`。自动流程优先使用高于现有标签的配置版本，构建号使用配置值与上个版本构建号加一中的较大值。Xcode 在打包时接收版本参数，源码提交和配置文件保留原样。[基础配置](../Config/Base.xcconfig)

需要手动准备时，在 Actions 中从 `main` 运行 `Release preview`，填写已存在的 `tag`，保持 `publish_existing_draft=false`。手动创建的历史格式标签仍按源码配置中的版本和构建号打包。打包或上传失败时可重跑失败任务。构建产物超过七天保留期，或旧任务重跑时原计划版本已被另一提交占用，则重跑整个流程。已有草稿不完整、标签与候选不一致或资产校验失败时，流程停止并保留现有材料供排查。

流程核对版本、标签与 `main` 祖先关系，锁定源码提交，运行 XCTest，再构建通用安装包。打包器保留 Widget，由内到外分别签名，并严格核对主应用／Widget 的身份、版本、URL、模型与 Intent 元数据、双架构以及签名权限，同时检查包内没有调试动态库。

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

记录 manifest 散列、标签和源码提交，安装并验证草稿中的候选。验收和公开必须使用同一组资产，不重建、不重签、不修改 Info 或重传替代资产。[Mac 分发验收规则](MAC-DISTRIBUTION.md#候选资产验收)

Git 历史重写前生成的候选保留原始 manifest 和源码提交。验收时记录 manifest 中的 `sourceCommit`，标签指向源码内容相同的重写后提交。发布器凭标签、新旧提交及 manifest SHA256 四项记录复核既有资产，新打包及上传的候选使用当前源码提交。[历史发行记录](../scripts/release-history-rewrite.json)

草稿仅供有仓库权限的维护者验收。公开记录应说明实际系统、硬件、验证范围和未覆盖项，不上传个人任务库、设备标识或原始私有日志。

## 公开已验收的草稿

**从 GitHub 网页发布。** 验收后在 Releases 打开对应草稿，点 **Edit** 编辑发行说明。发布正式版时，取消 **Set as a pre-release**，选中 **Set as the latest release**，再点 **Publish release**。在 Actions 的 [Mac update feed](https://github.com/JS-banana/lets-do/actions/workflows/mac-update-feed.yml) 查看应用内更新清单的同步结果。保留预发布选项即可只公开预览下载。

**从 Actions 发布。** 也可以在 `main` 手动运行 `Release preview`。这条路径在公开草稿前核对验收时记录的 manifest 散列，并为正式版预先签好更新清单。

| 输入 | 填写内容 |
|---|---|
| `tag` | 已验收候选的同一版本标签 |
| `publish_existing_draft` | `true` |
| `manifest_sha256` | 验收时记录的 `release-manifest.json` SHA256，64 位小写十六进制 |
| `make_latest` | 勾选后公开为正式 Release 并设为 Latest，默认公开为预发布版 |

发布器下载现有候选资产，重新核对源码、版本、构建号、manifest、归档散列及远端资产身份，确认 manifest 散列与输入一致后，直接公开同一个草稿。勾选 Latest 时，运行摘要会在 GitHub 确认 Latest 后给出链接。资产或标签发生变化、候选缺失或散列不符时停止。

候选准备、Actions 发版和更新清单写入共用并发组 `mac-release`。网页发布本身由 GitHub 立即完成，应用内可用时间以清单同步成功为准。

## Mac 应用内更新

带更新助手的候选仍交付同一组四份资产。安装过该版本的用户可从应用菜单检查更新，或开启定期检查。从 v0.3.x 升到 0.4.x 时应用身份和任务库路径都会变化，旧版无法自动更新。首个公开的 0.4.x 须在发行说明中手动补充：先在旧版导出 JSON 备份，退出旧版并移除旧小组件和旧应用，再手动安装 DMG、恢复备份、重新授权提醒事项并添加小组件。

**首次配置。** 在维护者 Mac 上运行以下命令，Sparkle 将该项目的 Ed25519 私钥保存在登录钥匙串。在 GitHub 仓库 Settings → Secrets and variables → Actions 中，将公钥设为变量 `SPARKLE_PUBLIC_ED_KEY`，将同一密钥的私钥设为 secret `SPARKLE_PRIVATE_ED_KEY`。密钥属于项目，长期备份，私钥不要放入源码、PR 或日志。公钥在合入后生成首份候选前配置，私钥在发布为 Latest 前配置。生成与导出选项见 [Sparkle 文档](https://sparkle-project.org/documentation/)。

```sh
sparkle_tools="$(python3 scripts/sparkle.py)"
"$sparkle_tools/bin/generate_keys" --account lets-do
"$sparkle_tools/bin/generate_keys" --account lets-do -p
```

**清单同步。** 网页发布后，`Mac update feed` 只处理 GitHub 当前的正式 Latest。它核对四份资产均由 GitHub Actions 上传，以 GitHub 记录的 manifest SHA256 校验下载内容，复核标签、源码和归档，再签署原 ZIP 与清单。写入 `mac-updates/appcast.xml` 前会再次确认 Latest 及其资产。客户端用包内公钥验证清单和 ZIP。两种发布方式都保留已有清单的验签与构建号防回退检查。

**旧草稿和重试。** GitHub 从发行标签读取发布事件工作流。早于此功能的草稿（包括 v0.4.5）在网页设为 Latest 后，由 `main` 上每小时一次的检查补同步。需要立即同步或修复失败后重试时，可在 `main` 手动运行 `Mac update feed`，无需填写参数或重新发版。相同候选已同步时只读检查即结束。更换签名密钥需要单独规划已安装用户的迁移。[GitHub 发布事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release)

**升级验收。** 在独立 macOS 测试用户中，使用同一测试公钥的两个连续构建。从可写的安装目录打开旧版，记录任务和未提交草稿，通过测试用已签名清单发现新版，点击安装、退出并重开。核对新应用和 Widget 的实际版本、原任务与草稿、Widget 刷新；损坏 ZIP 或错误签名应保留可运行的旧版。测试密钥与正式分发分开，正式清单只推送同一份已验收的候选。

## 本机打包与留证

需要 macOS、完整 Xcode 和公开的更新验签密钥。使用正式公钥或临时验证公钥打包：

```sh
SPARKLE_PUBLIC_ED_KEY="<公钥的 Base64 值>" python3 scripts/package-mac.py
```

默认输出到独立 `.build/packages/` 工作目录；也可使用 `--output-dir` 指定空的资产目录，或用 `--output` 指定 DMG 路径。输出已存在时拒绝覆盖，完整选项见 `python3 scripts/package-mac.py --help`。

打包不会安装或运行应用。Xcode 可能登记临时构建产物，脚本会精确注销本次主应用和 Widget 的构建路径；清理失败使打包失败，不做全局系统登记重置。原始日志与发布诊断按开发说明留存。[留证与日志](DEVELOPMENT.md#留证与日志)

本机包用于开发验证。正式候选由已校验标签的干净提交构建。
