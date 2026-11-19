# Mac 与系统提醒事项

Mac 主应用通过 EventKit 读写系统提醒事项。任务、周计划、正文版本、草稿和回收站由 TaskStore 管理。Widget 读取本机任务库，跨设备传播由系统提醒事项负责。操作步骤见[使用指南](USAGE.md#与手机上的提醒事项配合)。

## 导入映射与去重

| 情况 | 处理 |
|---|---|
| 未完成提醒的标题和纯文本备注 | 用 `TaskStore.createTask` 建立任务，有备注时一并创建初始正文版本 |
| 源截止日期或时间 | 只供候选行显示，本机任务的安排留空 |
| 重复、优先级、附件、子任务或闹钟 | 不写入任务模型，保留系统原项 |
| 已完成、已确认导入或能识别为已发送的提醒 | 从导入候选中排除 |
| 服务端事项标识缺失或在清单内重复 | 暂缓导入，保留原项 |

去重键由来源标识、清单标识和服务端事项标识组成。系统完整同步可能改变本机事项标识，服务端标识也可能重复，因此不能凭标题或截止日期认定同一事项。[本机标识](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier) · [服务端标识](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)

可写清单的选择和导入、发送关联随当前任务库保存在 `reminders-links.json`。导入时先持久化任务 UUID，再幂等创建任务，最后确认关联。中断后沿用同一 UUID。切库时丢弃旧库的异步响应。[MacReminders](../App/MacReminders.swift)

## 发送关联与失败处理

发送只接受当前库中未删除、未完成的任务。主应用先将任务 UUID、原清单、任务链接和可选截止日写入关联表，再创建系统提醒。EventKit 写入已保存的标题和任务链接，有截止日时只写年、月、日。[EventKit 全天截止](https://developer.apple.com/documentation/eventkit/ekreminder/duedatecomponents)

| 情况 | 处理 |
|---|---|
| 原清单中有唯一匹配 | 核对来源、清单、任务链接和事项身份后，保存服务端标识并确认发送 |
| 权限撤销或原清单不可用 | 暂停关联写入，恢复访问后仍按原清单核对 |
| 链接消失、匹配多条或事项身份变化 | 标记待核对，保留本机任务，不自动补发 |
| EventKit 保存中断或结果不确定 | 保留发送记录，刷新时先在原清单查找唯一匹配 |
| 用户确认重试尚未确认的发送 | 再查原清单。唯一匹配时恢复关联，多条时暂停，无匹配时才按原截止日重建 |
| 系统提醒延迟到达 | 手动重试仍可能产生重复。已确认的发送不允许重发 |

主应用在启动、回到前台及收到 `EKEventStoreChanged` 时重新读取已关联清单。自动刷新使用已有授权。重新选择清单只影响之后的导入和新发送，既有关联仍指向原清单。[AppModel](../App/AppModel.swift) · [TodoApp](../App/TodoApp.swift) · [EventKit 变更通知](https://developer.apple.com/documentation/eventkit/updating-with-notifications)

## 完成回写

只有发送关联的唯一匹配项可以触发完成回写。Mac 核实提醒已完成后，先在关联表预留稳定的操作 UUID。TaskStore 持写锁核对完整持久化历史中的事务作者，再将目标完成状态和操作凭据一同提交。历史消费只推进读取游标，保留操作凭据。[MacReminders](../App/MacReminders.swift) · [TaskStore](../Shared/TaskStore.swift)

| 情况 | 处理 |
|---|---|
| 写锁忙或数据库提交失败 | 保留操作 UUID 重试。期间编辑标题、正文或计划不影响这次完成 |
| 任务已提交，关联确认中断 | 重启或另一主应用实例按同一凭据确认，保留后来手动重开的状态 |
| 旧中断记录只有修改时间基线 | 提示在本机核对完成状态，不自动消费记录或再次完成任务 |
| 提醒取消完成、改名或被删除 | 保留原任务的状态、文字与计划 |
| 本机任务已删除 | 不恢复任务，不删除对应的系统提醒 |

## 权限与签名

主窗口切换任务库时更新提醒事项关联。Local 和 MacDistribution 主应用都声明 `NSRemindersFullAccessUsageDescription`，仅在用户主动授权时请求提醒事项完整访问。EventKit 没有只读提醒事项授权档位。[MacReminders](../App/MacReminders.swift) · [EventKit 授权](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)

打包脚本给最终主应用签入 `com.apple.security.personal-information.calendars`，并校验用途文案以及主应用和 Widget 各自的签名权限。该权限涵盖 EventKit 资源，主应用只请求提醒事项。ad hoc 构建覆盖升级后，系统隐私授权能否延续需真机验证。[打包脚本](../scripts/package-mac.py) · [Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime) · [代码签名身份](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## 验收步骤

使用可控提醒事项来源的单元测试覆盖导入、重试、标识变化、切库、写锁失败后编辑再重试，以及完成回写中断后的重开保护。存储测试覆盖操作凭据跨实例、历史消费和重启后的幂等性。[提醒事项测试](../Tests/MacRemindersTests.swift) · [存储测试](../Tests/TaskStoreTests.swift)

运行 Mac 单元测试，检查最终包的用途文案与签名。以下项目待真机验收，使用测试清单和同一份候选安装包，记录其 SHA-256。覆盖升级还需标明被替换的旧包。[检查与构建](DEVELOPMENT.md#检查与构建) · [本机打包](RELEASING.md#本机打包与留证) · [候选资产验收](MAC-DISTRIBUTION.md#候选资产验收)

1. **首次授权与撤销。** 在 Mac 上打开「待办」，确认启动无弹窗。打开导入面板，分别测试拒绝和授权、系统设置恢复、运行中撤销。已有任务仍可编辑。
2. **手机到 Mac。** 在 iPhone 的 iCloud 测试清单新增两条同名不同备注的待办，一条含到期时间。等 Mac 系统提醒事项也看得到后导入，核对备注、源截止和本机无日期。导入仅一条并重启，检查另一条仍可选。把导入任务移到回收站，再刷新，确认未被复活。
3. **清单和离线。** 准备同名本机清单和 iCloud 清单，只选择后者。断网新建手机提醒，联网后分别记录 Mac 系统清单和 Let’s Do 可见时间。移除原清单或切换账户后检查没有从另一份同名清单导入。
4. **安装包升级与 Widget。** 在相同安装路径用后一份真实 ad hoc 构建覆盖前一份，记录系统是否重新询问权限，复核关联保留、已导入任务可正常安排、Widget 按原任务显示。
5. **Mac 到手机。** 将一条「本周待安排」任务无截止发送，再将一条跨天任务指定独立截止日发送。分别核对 iPhone 系统提醒的标题和日期，以及 Mac 原计划。连续点击、切清单、退出重开后，检查原清单各只有一条。再打开导入面板，验证刚刚发送的提醒不能导入成第二条任务。
6. **离线完成和恢复。** 退出 Mac 应用，断网在手机上完成已发送项，恢复网络。等 Mac 系统提醒事项显示完成，再打开 Let’s Do，核对原 UUID 完成、备注和计划保留、Widget 随本机库更新。本机手动标回未完成，再刷新应保持未完成。另取一条只导入的原提醒，重复勾选操作，确认本机状态独立。
7. **识别失败。** 用测试清单验证手机删除、移动、改链接及清单授权撤销后，不误删本机、不自动补发、不把其他同名待办标为完成。记录候选安装包、系统版本、Mac 系统提醒是否已经收到、应用何时读取到。
