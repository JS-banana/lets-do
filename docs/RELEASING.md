# 构建与发布

## 当前分发边界

公开源码、CI 和安装包是三项独立交付。CI 无需签名凭据即可运行；保留系统 Widget 的发行包需要真实团队签名。首个公开安装包仍待维护者确认签名身份并配置凭据，不把无签名编译产物当作发行包。

目前以 Mac 本机预览版为范围：同一个包支持 Apple 芯片与 Intel，包含主应用与 Widget，不连接 iCloud。使用者不需要开发者会员。维护者的有效开发签名可用于开发预览；标准站外发行及 Apple 公证需要 Developer ID，当前未实现公证流程。

App Group 使用真实 Team ID 前缀，系统会核对签名身份。不能用随机 Team ID、自签名证书或删除权限检查来获得相同的共享能力。参见 [Apple 对 ad hoc App Groups 的说明](https://developer.apple.com/forums/thread/776087)。

## CI

`.github/workflows/ci.yml` 在 `main` 推送、Pull Request 和手动触发时运行。固定使用 GitHub 托管的 macOS 15 runner 和 Xcode 26.3，执行：

- Local Mac XCTest。
- Local 的 Mac、iPhone 模拟器及设备编译。
- CloudDevelopment 的无签名编译。
- DesktopLocal 主应用与 Widget 的无签名编译。

CI 只授予代码读取权限，不读取发行私钥；同一分支的新运行可取消旧运行。诊断报告与日志作为临时 Actions artifact 保存，不作为已验收的安装包。

## 配置发行签名

在仓库 **Settings → Secrets and variables → Actions** 中创建：

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | 有效 Apple 团队签名证书及其私钥的 `.p12`，转为 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 该 `.p12` 的导出密码 |
| `MACOS_TEAM_ID` | 与证书匹配的实际 Apple Team ID |

证书和私钥属于维护者凭据，不能提交到仓库、Issue 或公开 artifact。先确认使用哪份证书，再按 [GitHub 官方签名配置说明](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) 准备 Secrets。无需额外的 GitHub PAT；发布使用当前 workflow 的 `GITHUB_TOKEN`。

**签名证书会随应用公开。** manifest 不记录账户信息，也无法隐藏嵌入应用的证书署名。若开发证书的署名包含个人电话或其他不希望公开的信息，应先准备合适的签名身份，不直接上传旧的本机调试包。

Release 的签名步骤仅使用临时 keychain；无论构建成功或失败，都清理临时私钥文件和 keychain。原始签名日志不作为公开下载资产。

## 发布一个版本

1. 在 `Config/Base.xcconfig` 更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，提交到 `main`，等待 CI 通过。
2. 为待发布提交创建与版本一致的标签。例如当前版本对应：

   ```sh
   git tag v0.1.1
   git push origin v0.1.1
   ```

3. `Release` 自动运行。也可在 Actions 中手动运行，指定已经存在的版本标签。

流程先核对标签格式、版本号与提交来源，标签必须属于 `main` 历史，再读取签名 Secrets。任一校验失败、凭据缺失、签名不匹配或资产缺失时停止，不发布空版本，也不回退到无签名包。

发布资产包括通用 `.dmg`、保留包结构的 `.zip`、`SHA256SUMS` 与记录版本／源码提交／构建校验的 manifest。先创建草稿、上传完整资产，再发布为预览版，避免下载页面只有部分文件。

下载后可以在文件所在目录核对：

```sh
shasum -a 256 -c SHA256SUMS
```

## 本机打包

准备有效的 `Config/Signing.local.xcconfig` 后：

```sh
python3 scripts/package-mac.py
```

打包复用 DesktopLocal，不安装或运行应用。它会校验主应用与 Widget 的签名、共享组、双架构与源码稳定性，拒绝调试 dylib、调试权限和意外的云权限。构建日志保存在 `.build/`；具体输出参数可通过 `python3 scripts/package-mac.py --help` 查看。

构建与签名通过后，仍需分别核对原生启动、系统搜索、Widget 注册与读写。编译和公证都不替代真实设备、CloudKit 或跨设备数据验收。
