# 构建与发布

## 下载版

Mac 下载版采用 `Local` 主应用，支持 macOS 14 及以上、Apple 芯片与 Intel。GitHub Actions 使用 ad hoc 签名校验包的完整性，不需要 Apple 开发者证书、私钥或付费会员，也不需要配置仓库 Secrets。

应用未经过 Apple 公证。用户首次打开时可能需要在「系统设置 → 隐私与安全性」中单独允许这个应用；不要求关闭系统全局保护。

此下载版不连接 iCloud，不嵌入系统桌面 Widget。源码保留的 DesktopLocal 共享容器需要真实团队签名，不能通过随机 Team ID 或自签名替代；参见 [Apple 的 App Groups 说明](https://developer.apple.com/forums/thread/776087)。这些开发能力不阻塞普通主应用的公开分发。

## CI

`.github/workflows/ci.yml` 在 `main` 推送、Pull Request 和手动触发时运行。固定使用 GitHub 托管的 macOS 15 runner 和 Xcode 26.3，执行：

- Local Mac XCTest。
- Local 的 Mac、iPhone 模拟器及设备编译。
- CloudDevelopment 的无签名编译。
- DesktopLocal 主应用与 Widget 的无签名编译。

CI 只授予代码读取权限，不读取维护者凭据；同一分支的新运行可取消旧运行。检查报告作为短期 Actions artifact 保存，不代表设备／云功能已经运行验收。

## 发布一个版本

1. 在 `Config/Base.xcconfig` 更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，提交到 `main`，等待 CI 通过。
2. 为待发布提交创建与版本一致的标签。例如当前版本对应：

   ```sh
   git tag v0.1.1
   git push origin v0.1.1
   ```

3. `Release preview` 自动运行。也可在 Actions 中手动运行，指定已经存在的版本标签。

流程校验标签格式、版本及 `main` 祖先关系，锁定源码提交，运行 XCTest，再构建通用 Mac 主应用。打包会移除构建过程中的 Widget 扩展，对最终应用重新进行 ad hoc 签名，并核对架构、权限、源码稳定性及归档完整性。

下载资产包括 `.dmg`、保留包结构的 `.zip`、`SHA256SUMS` 与记录版本／源码提交／校验结果的 manifest；两种归档均携带 MIT LICENSE。先创建发行草稿、上传并核对全部资产，最后公开为预览版。校验或构建失败时停止，不发布空版本。

发布 job 使用 GitHub 自带的 `GITHUB_TOKEN`，仅该 job 授予 `contents: write`。无需额外 PAT、Apple 账户、签名 Secrets、临时 keychain 或本机机器参与构建。

下载后可以在文件所在目录核对：

```sh
shasum -a 256 -c SHA256SUMS
```

## 本机打包

需要 macOS 和 Xcode，无需签名配置：

```sh
python3 scripts/package-mac.py
```

打包不会安装或运行应用。构建、检查与完整日志保存在被忽略的 `.build/`；输出参数见 `python3 scripts/package-mac.py --help`。

原生启动、系统搜索与实际用户安装分别验证；构建通过不替代运行验收。iPhone、CloudKit 与带共享权限的系统 Widget 仍按开发配置独立核对，不作为此无证书 Mac 下载版的功能声明。
