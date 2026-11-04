# 构建与发布

## 分发包与 CI

Mac 下载包使用 `MacDistribution`，包含主应用和原生今日、周、月 Widget，支持 macOS 14 及以上的 Apple 芯片与 Intel Mac。主应用非沙盒，Widget 保留沙盒；两者分别采用 ad hoc 完整性签名，无 Apple 开发者证书、私钥、团队或 App Group，也不连接 iCloud。存储与升级约束见 [Mac 分发说明](MAC-DISTRIBUTION.md)。

应用未经过 Apple 公证。首次打开可能需要在「系统设置 → 隐私与安全性」中单独允许该应用；不要求使用者提供开发者账号或关闭系统全局保护。

[CI workflow](../.github/workflows/ci.yml) 在 `main` 推送、面向 `main` 的 Pull Request 和手动触发时运行，使用 GitHub 托管的 macOS 15 runner 与 Xcode 26.3，执行[开发说明](DEVELOPMENT.md#检查与构建)中的 XCTest、Local、CloudDevelopment、DesktopLocal 和 MacDistribution 编译。CI 仅有代码读取权限，同一分支的新运行可取消旧运行，摘要 artifact 保留七天。它不替代 GUI、Widget、升级或 Gatekeeper 验收。

## 先生成候选草稿

[Release preview](../.github/workflows/release.yml) 将构建候选和公开发行分成两个步骤。推送版本标签默认只准备草稿，**不会自动公开**。

1. 在 [Base.xcconfig](../Config/Base.xcconfig) 更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，提交到 `main`，等待 CI 通过。
2. 为待发布提交创建与版本一致的标签。以 `v0.2.0` 为例：

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. 等待 `Release preview` 的 `validate`、`build`、`prepare` 完成。也可从 `main` 手动触发，填入已存在的 `tag`，保持 `publish_existing_draft=false`。

流程核对标签格式、远程标签、标签中的版本与 `main` 祖先关系，锁定源码提交，运行 XCTest，再构建通用安装包。打包器保留 Widget，由内到外分别签名，并严格核对主应用／Widget 的身份、版本、URL、模型与 Intent 元数据、双架构以及权限；拒绝团队证书、App Group、云权限、调试权限及调试动态库。

候选草稿必须恰好包含四份资产：

- `lets-do-<版本>-macos-universal.dmg`
- `lets-do-<版本>-macos-universal.zip`
- `release-manifest.json`
- `SHA256SUMS`

DMG 与 ZIP 携带同一份应用及 MIT LICENSE。manifest 记录源码提交、版本、构建号、源码散列、归档散列和包校验结果；它的运行验收字段明确只代表构建与打包检查。

`prepare` 上传并核对资产后保留草稿，输出候选 manifest 的 SHA256。已有同标签的草稿或发行版时拒绝覆盖；失败时仅尝试删除本次新建、尚未完成的草稿，不覆盖已有发行资产。需重新构建时，先查明失败及保留材料，再决定新的候选，不使用重传掩盖差异。

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

此次运行跳过构建和候选上传。发布器下载现有草稿资产，重新核对源码、manifest、归档散列及远端资产身份，确认 manifest 散列与输入一致后，将同一个草稿公开为预览版。**不重新编译、不重新签名、不重新上传资产。** 资产或标签发生变化、草稿缺失或散列不符时停止。

`prepare` 与 `publish` job 使用 GitHub 自带的 `GITHUB_TOKEN`，仅这两个 job 获得 `contents: write`。无需额外 PAT、Apple 账户、签名 Secrets、临时 keychain 或维护者本机参与 CI 构建。

## 本机打包与留证

需要 macOS 和完整 Xcode，无需签名配置：

```sh
python3 scripts/package-mac.py
```

默认输出到独立 `.build/packages/` 工作目录；也可使用 `--output-dir` 指定空的资产目录，或用 `--output` 指定 DMG 路径。输出已存在时拒绝覆盖，完整选项见 `python3 scripts/package-mac.py --help`。

打包不会安装或运行应用。Xcode 可能登记临时构建产物，脚本会精确注销本次主应用和 Widget 的构建路径；清理失败使打包失败，不做全局系统登记重置。报告、完整日志与发布诊断只保留在被忽略的 `.build/`，不作为下载资产上传。

本机包用于开发验证。正式候选由已校验标签的干净提交构建；本机检查、隔离安装证据与正式候选验收必须分别记录。
