# AGENTS.md

## 方向与范围

在 Mac 上记录任务、安排一周。手机端借用系统提醒事项。iPhone 应用、CloudKit、App Group 和公证都在项目范围外，勿建议开通付费开发者账号。

## 协作

- 默认用中文。先看当前差异和相关流程，保留他人改动。同一时间只有一个编码代理，只读审查可以并行。本机 shell 遵循使用者的工具约定，CI 使用 runner 自带工具。
- PR 用 squash 合入。叠放的 PR 在前一个合入后用 `git rebase --onto` 移到新基线。更改 PR 的 base 后，关闭再重新打开 PR 以触发 CI。
- 方案放在 `.build/plans/`。合入后把仍有效的约束写回负责该主题的文档。按读者用途整理，入口只放摘要和链接。

## 文档地图

- [README](README.md) 介绍产品和下载入口。[使用指南](docs/USAGE.md) 说明安装、日常操作、提醒事项和备份。
- [开发说明](docs/DEVELOPMENT.md) 记录配置、源码、数据规则和验证边界。[产品与界面设计](docs/PRODUCT-DESIGN.md) 说明任务语义和界面交互。
- [Mac 分发说明](docs/MAC-DISTRIBUTION.md) 定义容器、更新助手和系统验收。[提醒事项实现](docs/MAC-REMINDERS.md) 说明 EventKit 关联、权限和真机验收。
- [发布说明](docs/RELEASING.md) 说明如何构建、验收和公开候选资产。

## 改动与验证

- 用 `python3 scripts/check.py unit` 跑测试，用 `python3 scripts/check.py distribution-build` 验证分发配置。Local 编译只覆盖开发版。自动运行按[隔离运行](docs/DEVELOPMENT.md#隔离运行)设置 `-LetsDoRun`。
- 改动用户可见行为时更新使用指南和 README。按[留证与日志](docs/DEVELOPMENT.md#留证与日志)报告结果，原生 GUI 没有实际操作时写明「未验证」。
- 推送到 `main` 并通过 CI 后会自动生成 Release 草稿。只公开已验收的草稿。

## 数据不变量

- 所有任务入口复用 TaskStore。事务提交后才反馈成功。
- 正文追加不可变版本，保留父关系和全部分支。用 tombstone 删除任务，恢复须显式操作。
- 整体写入并校验计划。草稿按库保存，任务提交成功后才清理。
- 主应用负责建库和迁移。扩展只打开已核验的现有库，保留会话、模型租约和写锁。
- 模型、授权或启动检查失败时保留原库与草稿，不删库重建，不静默回落空库或默认库。修改存储、日期或 Intent 前核对共享实现和调用方。[数据规则](docs/DEVELOPMENT.md#数据规则)

- 提醒事项关联文件加入的字段必须是 Optional，保留旧文件的读取能力。
- 在写 EventKit 前先持久化任务与提醒的关联或预留记录，恢复时核对原清单和事项身份。
- 读不出的任务保留原记录与对应提醒。只有读到明确的回收状态，才能删除已核实的同步提醒。
- 相同状态连续同步两次，第二次对 EventKit 的写入次数必须为零。

## 不入库

凭据、本机签名配置、个人路径、设备标识、数据库与原始私有日志留在本机。
