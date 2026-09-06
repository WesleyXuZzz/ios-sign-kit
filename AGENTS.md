# AGENTS.md

## 项目概览

- 这是一个基于 `Swift 6.3`、`SwiftUI`、`AppKit` 的 macOS 菜单栏应用。
- 正式展示名是 `iOSSignKit`，中文副标题是“iOS 个人签名续期工具”。
- Swift Package 名称是 `ios-sign-kit`，可执行产品名是 `IOSSignKit`。
- 应用用途是在 macOS 菜单栏中检查目标 iPhone 是否已连接，并在到期时提醒或按策略自动刷新指定 iOS App 的个人开发签名；用户显式启用后，也可通过经认证的局域网页面查看状态、重新检查或发起无需现场选择 Profile 策略的续签。
- 应用本体不是 iOS 工程，而是一个帮助外部 iOS 项目完成真机刷新部署的辅助工具。

## 仓库结构

- `Sources/IOSSignKit`：主应用源码，包含入口、状态栏控制、视图、ViewModel、模型与服务。
- `Sources/IOSSignKit/Resources/LANControlWeb`：局域网控制页的 HTML、CSS 与 JavaScript 静态资源；必须通过运行时资源清单进入 App。
- `Tests/IOSSignKitTests`：单元测试，当前覆盖环境推断、过期时间推断、提醒策略、设备匹配等核心逻辑。
- `scripts/build-app.sh`：将 SwiftPM 构建产物组装为标准 macOS `.app`；只有显式传入 `dmg` 时才生成 APFS + LZFSE 压缩的可拖拽安装 DMG。
- `scripts/install-app.sh`：核验并将 `dist` 中的正式 App 移动到 `/Applications`；已有同身份安装先移入废纸篓，失败时尝试回滚，不负责构建、启动或强退 App。
- `scripts/verify-release-artifacts.sh`：对 release App/DMG 执行签名、图标、资源边界、压缩格式、卷结构与体积指标验收。
- `scripts/verify-test-concurrency.sh`：连续运行重点异步套件或完整测试集，保留首次失败退出码；默认使用 Swift Testing 并发模式，`--no-parallel` 只用于串行诊断。
- `scripts/audit-workspace-size.sh`：只读盘点项目、构建缓存、Git 对象与本地产物占用，不执行清理。
- `scripts/verify-public-source.sh`：只读检查准备公开的提交及其完整可达历史，拒绝 shallow、replacement refs 与 grafts，要求 GitHub noreply 提交身份，并拒绝凭据、本机路径、非源码产物和已退出的公开流程标记。
- `scripts/push-source-mirrors.sh`：冻结已验证的本地提交与实际 push URL，隔离网络 Git 配置和本地 hook，持续复核 remote URL 配置，并对 GitHub 与私有镜像执行双端 fast-forward 预检、仅 `master` 的顺序推送和目标 OID 复核；不执行 force 或自动历史协调。
- `docs/ui-guidelines.md`：当前长期有效的界面、交互、视觉和可访问性规范；以最新生产代码、契约测试和真实运行界面为准。
- `docs/architecture.md`：当前长期有效的系统边界、运行链路、核心模块职责和业务不变量。
- `dist/`：生成的 `.app` 与 `.dmg` 测试包输出目录。
- `runtime/`：本地调试、截图和视觉 QA 等临时生成物目录，默认由 Git 忽略；需要长期保留的核心规则应归并到 `AGENTS.md`、`README.md` 或契约测试，不保留独立实施计划作为第二事实源。
- `workbench/`：本地开发工作台，用于存放开发方案、设计稿、实验原型及配套素材；除用于保留目录的 `.gitkeep` 外，其余内容默认由 Git 忽略。每项工作可在其中按主题新增子目录和文件。
- `.build/`：Swift Package Manager 的构建产物目录。
- `.swiftpm/`：SwiftPM/Xcode 相关配置目录。

## 文档治理

- `docs/` 纳入版本控制，当前只长期维护 `ui-guidelines.md` 与 `architecture.md` 两份文档；历史设计轮次、一次性实施计划、截图比对记录和阶段性修复说明不得继续作为并行事实源。
- AI 生成的开发方案、设计稿、实验原型和配套素材应保存到 `workbench/` 下按主题划分的子目录中，不直接新增到 `docs/`；该工作区内容仅用于讨论和迭代，不作为项目事实源，也不得被强制加入 Git。
- 当工作区中的结论需要成为长期约束时，应先与用户确认，再归并到 `AGENTS.md`、`README.md`、现有长期文档、代码或契约测试中；完成归并后仍不需要提交原始工作稿。
- 当项目结构、模块边界、主流程、导航信息架构、视觉系统或交互设计发生变化时，必须先向用户确认对应文档的更新范围；得到确认后才能修改长期文档。
- 需要在 `docs/` 中新增、拆分或重命名文件时，必须先向用户说明用途、与现有两份文档的边界以及长期维护方式，并取得确认。
- 文档结论按“当前生产代码与测试契约 → 最新真实运行界面 → 已确认的历史设计决策”取舍；历史材料与现状冲突时，以前两者为准，并将仍有效的约束归并到长期文档。

## 运行与构建

常用命令：

```bash
swift build
swift test
./scripts/verify-test-concurrency.sh --iterations 20
open Package.swift
./scripts/build-app.sh
./scripts/build-app.sh --clean
./scripts/build-app.sh dmg
./scripts/build-app.sh --debug
./scripts/install-app.sh
./scripts/install-app.sh --dry-run
./scripts/audit-workspace-size.sh
./scripts/verify-public-source.sh
./scripts/push-source-mirrors.sh --dry-run
./scripts/push-source-mirrors.sh
```

补充说明：

- 这是 `Swift Package` 项目，不是以 `.xcodeproj` 作为主工程入口。
- `open Package.swift` 可以用 Xcode 打开并直接运行 `IOSSignKit`。
- GitHub `master` 是唯一日常开发事实源，私有 remote `private` 只镜像相同提交 OID；迁移前的私有历史必须保存在独立只读备份中，不得继续作为日常开发分支。
- 所有 Git 跟踪文件、提交消息及作者和提交者身份都属于公开源码边界。公开提交必须来自完整、没有 replacement refs 或 grafts 的仓库并使用 GitHub noreply 邮箱；提交后先运行 `scripts/verify-public-source.sh`。需要同步远端时统一使用 `scripts/push-source-mirrors.sh`，并以 GitHub `origin/master`、私有 `private/master` 与脚本冻结的本地提交三方 OID 全部一致作为成功条件。`origin` 的唯一 fetch 与 push URL 必须在协议、主机、默认端口和路径归一化后指向 `WesleyXuZzz/ios-sign-kit` GitHub 仓库，任何 Git URL 重写都失败关闭。网络 Git 子进程使用冻结 URL、隔离 Git 配置并禁用本地 hook、自动标签和递归子模块推送。
- 双远端推送不是跨服务器原子事务。脚本固定先预检两端、再推私有镜像、最后推 GitHub；任何部分成功都返回非零且不得通过 force、自动 pull、merge 或 rebase 掩盖分叉。
- 初版公开发布只包含源码、文档和已授权项目资产，不发布官方预编译 `.app` 或 `.dmg`。
- `scripts/build-app.sh` 会执行 `swift build`、组装 `.app`、写入 `Info.plist`、设置 `LSUIElement`、在 release 构建中默认使用 `-Osize`、`-debug-info-format none` 并执行 `strip -x`。签名默认使用 ad-hoc；显式提供 `IOS_SIGN_KIT_CODE_SIGN_IDENTITY` 时使用对应身份，但不得把证书名称或本机身份写入项目配置。只有显式传入 `dmg` 时才生成包含“应用程序”快捷入口的 APFS/ULFO DMG。需要保留 release DWARF/dSYM 时可设置 `RELEASE_DEBUG_INFO_FORMAT=dwarf`，该变量只接受 `none` 或 `dwarf`，不影响 debug 构建。
- 根目录 `AppIcon.icon` 是正式 App Icon 的唯一打包源；脚本只将现代 `Assets.car` 放入 App，并按图标输入、Xcode、SDK 与编译参数缓存到 `.build/generated-app-icon`。SwiftPM 运行时资源中不得再保存或打包 App Icon 副本。
- 打包脚本按 `config/runtime-resources.tsv` 复制运行时资源，以避免 SwiftPM 旧缓存重新带入已排除资源；新增或移除通知图片、局域网页面静态文件等运行时资源时只修改该 manifest，`build-app.sh`、`PackagedResourceContractTests` 与 `verify-release-artifacts.sh` 会共同消费它。四张标记为 `notification-attachment` 的通知附件必须保持 `256 × 256` 且不带 Alpha。
- 日常重复打包不应主动清理 `.build`，否则会同时丢失 SwiftPM 与 App Icon 的增量缓存。
- 只有需要测量项目级冷构建或明确排除增量缓存影响时才使用 `./scripts/build-app.sh --clean`；该参数会在取得打包锁后递归删除当前项目的 `.build`，但不触碰 `dist`、`.swiftpm` 或全局 SwiftPM/Xcode 缓存。紧接着执行一次默认命令可测量热缓存构建。
- 日常功能验证直接使用默认命令 `./scripts/build-app.sh` 复用缓存并跳过 DMG；正式 release 验收再执行 `./scripts/build-app.sh dmg` 与 `verify-release-artifacts.sh`。
- `scripts/audit-workspace-size.sh` 只报告磁盘占用和清理候选；任何缓存、遗留产物或 Git 对象清理仍需单独确认。
- `scripts/build-app.sh` 默认打包 release `.app`，也兼容显式传入 `app`；只有传入 `dmg` 才生成 DMG。`./scripts/build-app.sh --debug` 默认生成 debug `.app`，调试 DMG 使用 `./scripts/build-app.sh dmg --debug`。
- `scripts/install-app.sh` 只移动并安装正式 `dist/iOSSignKit.app`，与打包流程共用 `dist/.build-app.lock`；安装前核验应用身份和签名，应用仍在运行、目标身份不同或目录不可写时直接停止。已有安装只移动到废纸篓，不递归删除；`--dry-run` 只执行预检。
- `config/release-metadata.json` 是正式展示名、可执行名、Bundle ID、Marketing Version、Build Version 与最低 macOS 版本的唯一发布元数据；正式 Bundle ID 为 `com.xuzw.iossignkit`。
- Marketing Version 固定使用三段式数字版本：兼容修复递增 Patch，向后兼容的新功能递增 Minor，存在明显不兼容变化时递增 Major。首个正式版本为 `1.0.0`。
- Build Version 使用从 `1` 开始的全局递增正整数；每次生成准备分发、安装验收或正式测试的构建时递增，同一 Marketing Version 重新打包时也必须递增，普通代码提交不递增。
- 主界面顶部命令栏只常驻显示 Marketing Version；Build Version 只在悬停说明、辅助功能文本和诊断信息中展示。发布版本只修改 `config/release-metadata.json`，不得在界面代码、README 或测试中复制当前版本值。
- release 构建禁止通过 `BUNDLE_IDENTIFIER` 或 `BUNDLE_VERSION` 改写正式身份；如需多渠道构建，应新增显式 profile。元数据缺失、内容非法或发生覆盖尝试时必须在 Swift 构建前失败。

## 修改后验证约定

- 修改常规功能逻辑或界面展示代码后，默认仅进行与改动直接相关的代码检查和必要测试，不进行打包、安装或启动 App 的运行验收；也不主动执行自动截图、基于截图再次修改或重复进行视觉复核。
- 用户明确要求对新版本进行安装运行验收时，按以下顺序执行：
  1. 使用 `./scripts/build-app.sh` 构建 release App；除非用户同时明确要求 DMG 或完整 release 产物验收，否则不生成 DMG。
  2. 确认当前 iOSSignKit 是否正在执行目标 App 的重新签名安装；如果正在执行，持续等待该操作结束，不取消部署，也不强制退出 iOSSignKit。
  3. 签名安装结束后，正常退出当前运行的 iOSSignKit App（如存在），但不修改或停用登录启动项。
  4. 使用 `dist/iOSSignKit.app` 替换 `/Applications/iOSSignKit.app`；旧 App 不存在时直接安装到该位置。
  5. 启动 `/Applications/iOSSignKit.app`，确认系统中只有一个 iOSSignKit 实例，再执行用户明确要求的验收内容。
- 如果无法确认签名安装是否已经结束、旧 App 无法正常退出，或无法完成 `/Applications/iOSSignKit.app` 的替换，则停止运行验收并向用户报告阻碍；不得强制终止进程或破坏现有安装。
- 修改构建脚本、打包流程、应用包结构、`Info.plist`、签名或 DMG 生成等构建打包相关内容后，默认执行受影响的打包流程进行产物验证；没有特殊说明时，先使用项目默认的 release App 打包命令 `./scripts/build-app.sh`。涉及 DMG 或完整 release 产物验收时，再执行 `./scripts/build-app.sh dmg` 与 `./scripts/verify-release-artifacts.sh`。产物验证不自动升级为安装运行验收。
- 如果修改范围横跨常规功能、界面展示与构建打包等多个类别，或无法确定修改完成后是否需要自主打包验证，应先向用户确认验证范围、产物类型和构建模式，得到明确答复后再执行打包。
- 上述约定只限制打包、安装运行验收、自动截图和由截图触发的视觉迭代，不排除与修改直接相关的静态检查、单元测试或普通构建验证。

## 核心架构

- `IOSSignKitApp`：SwiftUI 应用入口。
- `AppBootstrapper`：启动时加载配置与运行状态，迁移并清除旧 `deployScriptPath`，在确认遗留部署进程结束后按“构建工作区清理 → Provisioning Profile 缓存恢复 → 宿主安装回执核对”的顺序恢复异常退出状态，并执行环境校验。
- `AppDelegate`：获取应用单实例锁，执行遗留普通命令与部署进程的启动恢复，初始化主 ViewModel 与状态栏控制器，并在启动后预加载主面板、触发首次环境刷新。
- `ApplicationInstanceLock`：通过用户应用支持目录中的文件锁阻止多个 iOSSignKit 实例并发运行。
- `CommandProcessRecovery` / `DeploymentProcessRecovery`：在真实应用入口扫描并核验遗留普通命令与部署进程；只有精确归属可证明时才终止，无法确认时保持刷新阻断。
- `StatusBarController`：管理菜单栏状态项、带动态双行状态头的右键菜单、主窗口显示/隐藏，以及从菜单触发“重新检查 / 重新签名并安装 / 打开项目 / 退出 iOSSignKit”等操作。
- `StatusMenuHeaderPresentation` / `StatusMenuHeaderView`：根据环境、设备、签名和操作状态生成并展示右键菜单顶部的动态摘要。
- `MenuBarViewModel`：主界面状态 façade，负责发布 SwiftUI 与局域网控制页需要的状态、接收用户意图，并编排设备刷新、自动刷新、部署事务、状态结算与系统集成。
- `RefreshScheduler`：刷新链路统一的业务时间边界，同时提供墙钟时间与可取消等待；生产统一使用 `continuous` adapter，测试使用手动 adapter 推进虚拟时间，禁止为倒计时、自动等待、系统唤醒补检、连接确认或安装检查重试重新引入彼此独立的时钟与 sleep 注入。
- `DeviceRefreshSession`：持有设备刷新主任务和扫描代次，拒绝过时结果回写；被取消或取代的任务仍跟踪到闭包真正返回，确保 fixture 和宿主能够等待完整结算。
- `DeviceRefreshWorkflow`：接收不可变刷新请求，集中完成环境验证、检测策略选择、设备扫描、目标匹配、安装检查和会话缓存更新，并返回无界面副作用的类型化转移结果。
- `DeviceRefreshSnapshotReducer`：把刷新快照与当前会话状态归约为单一应用计划，联合决定连接阶段、安装身份、有效期、缓存失效和关键动作抑制；不得在该模块中调度任务、发送通知或修改界面对象。
- `DeploymentTransactionCoordinator`：持有部署预检任务、已启动部署进程、事务上下文及取消/终止转移，区分“请求取消并等待结算”和“立即释放预检”两种语义；业务状态释放后仍保留已取消任务直到闭包返回。
- `DeploymentPreflightWorkflow`：按固定顺序执行最终设备复核、锁态、静态环境、App 目标、Xcode destination、自动安装身份和提交前二次解锁校验；只返回已授权目标或类型化阻断结果，不直接启动部署进程。
- `AutomaticRefreshCoordinator`：持有自动刷新倒计时，并组合单一 `AutomaticRefreshWaitCoordinator` 管理锁屏、锁态未知和 destination 准备等待。
- `RefreshStateSettlement`：集中执行设备观察、安装身份与部署结果到 `AppState` 的跨字段映射；常见写入通过类型化事件按“复制、保存、发布”顺序提交。
- `PrimaryJourneyPresentation`：将项目配置、设备状态、签名状态、安全主动作和最近结果映射为“当前状态”页的主旅程展示模型。
- `RenewalIconPresentation` / `SidebarBrandIcon`：将续期图标的业务颜色与运动阶段分离；绿色只表示当前成功反馈，历史成功不得恢复绿色；顶部命令栏使用 `30pt` Renewal Loop、支持 Reduce Motion，并在工作台不可见时暂停且恢复后不追赶后台时间。
- `OperationActivityPresentation`：将检查、倒计时、部署、自动恢复、结算结果与通用反馈映射为类型化展示状态和动作；当前部署反馈与历史刷新结果分开判断。
- `ActivityFocusCard` / `DeployLogPopover`：在“当前状态”主旅程中展示当前操作、上下文动作和进度反馈，并通过主面板浮层按需展示部署日志。
- `SetupWizardViewModel`：负责首次配置与设置页编辑，包括项目目录选择、项目路径自动推断、多 App 候选选择、设备扫描、固定目标设备、离线固定设备名称、续期频率、局域网控制草稿与配置保存。多候选只在与已保存配置存在唯一精确匹配时自动恢复，否则必须由用户明确选择。
- `LANControlConfiguration` / `LANControlPasswordCredential`：保存局域网监听主机、端口、启用状态和加盐迭代摘要；配置中不得保存控制密码明文。
- `LANControlServerController` / `LANControlHTTPApplication`：使用 Network.framework 启停本机 HTTP 监听，拒绝非本地网络来源，提供静态控制页、登录/配对、状态读取、重新检查和续签接口；远程动作仍通过 `MenuBarViewModel` 进入既有安全判断。
- `LANControlSnapshot` / `LANControlProtocol`：把设备、签名和操作阶段投影为不包含部署授权能力的传输模型；浏览器不能自行构造部署目标或选择 Profile 策略。
- `CommandRunner` / `RunningCommand` / `CommandProcessOwnershipTracker` / `CommandOutputCollector`：分别承担命令 façade、运行生命周期、进程所有权与有界输出收集，补齐常见 PATH，支持实时 stdout/stderr 回调与运行中取消。
- `DeviceMonitor` / `DeviceSourceScanner` / 来源解析器 / `DeploymentTargetAuthorizer`：分别承担设备证据协调、来源命令执行、纯解析和最终部署授权；来源结果区分完整、部分和失败，传输级不确定证据不会再被压缩成设备全局不可用。正式 `DeploymentTarget` 的构造能力封闭在授权器内，compatibility 单清单目标使用独立类型，部署提交点按检测策略校验两者不可混用。
- `DeviceConnectionReducer` / `SystemWakeMonitor`：独占会话内连接确认暂态，并在系统唤醒后清理旧证据、取消尚未执行的关键动作；普通状态下安排 `+5`、`+20` 秒补检，自动刷新等待期间则交由等待协调器执行同样的唤醒节奏，避免并发扫描；已进入运行态的部署不会被唤醒取消。
- `DeviceDetectionRolloutController` / `DeviceDetectionRolloutConfiguration` / `DeviceDetectionComparison`：集中控制 `fallback`、`shadow`、`readOnly` 与 `production` 模式，并用同一轮来源快照记录无身份信息的分类差异；生产缺省使用 `production`。环境变量 `IOS_SIGN_KIT_DEVICE_DETECTION_POLICY` 只接受这四个值，旧值、空值或其他非法非空值失败关闭到 `readOnly` 并显示诊断。设置页设备扫描遵循同一策略；预检期间切换会立即取消预检，已经运行的部署则在结算后应用切换。
- `RefreshPolicy` / `RefreshSessionCaches`：决定后台心跳、App 补查和完整交互检查，并提供按目标代次绑定的 Xcode/App 会话缓存；缓存只用于候选筛选，不能直接授权提醒、配对、倒计时或部署。
- `DeviceMatcher`：返回类型化匹配结果；固定设备 ID 缺失时禁止回退，同名设备视为歧义。
- `DevicePairingService`：通过 `xcrun devicectl manage pair` 尝试恢复符合条件的无线设备，并区分需要确认、网络不可用和其他失败。
- `DeviceAppInspector`：通过 `xcrun devicectl` 查询目标 App 是否安装在设备上，并尝试读取安装元信息。
- `XcodeProjectLocator`：递归发现项目目录中的 `.xcodeproj` 与 `.xcworkspace`，同时排除隐藏目录、依赖目录、构建产物目录和 `.xcodeproj` 内部生成的重复 Workspace。
- `XcodeProjectResolver`：通过 `xcodebuild -list -json` 与 `-showBuildSettings -json` 识别真实 Scheme、`iphoneos` App Target 与 Bundle ID；混合平台 Workspace 中只跳过可确认不包含 iOS App 的 Scheme。
- `XcodeDestinationReadinessInspector`：部署前通过 `xcodebuild -showdestinations` 按完整设备 ID 检查目标是否可用，并区分需解锁、不可用和无法确认。
- `AutomaticRefreshWaitCoordinator`：在到期自动刷新遇到锁屏、锁态未知或 Xcode destination 准备中时维持单一等待任务；统一承接周期探测、系统唤醒和用户“立即检查”，并在目标、安装实例或策略变化后丢弃旧结果。
- `DeployService`：把已授权目标适配为内置标准部署请求，返回可取消的 `RunningDeploy`，并将有界 stdout/stderr、精确 Profile 有效期和恢复确认状态写入日志与部署结果。
- `StandardIOSDeploymentExecutor`：直接编排 `xcodebuild -showBuildSettings`、Profile 缓存事务、真机 Build、已签名产物核验、宿主回执、`devicectl install` 与可选 Launch；所有外部阶段都有有限超时，构建只写入按精确部署令牌隔离的私有 DerivedData。
- `ProvisioningProfileCacheManager` / `ProvisioningProfileCacheTransaction`：在 Xcode UserData 与 MobileDevice 两个标准缓存目录中按 Team + Bundle ID 精确处理 Profile；`auto` 只隔离过期匹配项，`force` 隔离全部匹配项，并以带摘要的持久化事务支持 commit、rollback 与崩溃恢复。
- `SignedIOSAppInspector`：安装前核验受控 DerivedData 内唯一 `.app` 的 Bundle ID、Info、可执行文件、代码签名、Team、设备授权、Profile 摘要与精确到期时间，拒绝路径逃逸、符号链接替换和不完整命令结果。
- `HostInstallReceiptStore`：按精确部署令牌保存 `prepared` / `installed` 宿主回执，记录设备、Bundle、Team、版本和已核验 Profile，使用带 SHA-256 的有界原子文件支撑安装后崩溃恢复。
- `DeployFailureAnalyzer`：统一分析实时结果与历史日志，识别结构化失败标记及可安全绑定目标设备的旧版 Xcode destination 错误。
- `ReminderPolicy`：根据设备在线状态、预计过期时间、冷却时间、部署状态与安装状态判断是否需要提醒或进入自动刷新。
- `ExpiryInspector`：负责推断预计过期时间，优先使用安装元信息，其次使用已存储过期时间，最后退化为基于上次成功安装的估算值。
- `RefreshStateStore`：持久化配置与运行状态。
- `LogStore`：管理部署日志文件；默认最多保留最近 200 份、合计不超过 256 MiB，并至少保留最新一份。
- `RefreshHistoryService`：从日志目录分页提取历史刷新记录并生成展示摘要，能识别成功、失败与取消状态。
- `LaunchAtLoginService`：优先通过 `SMAppService.mainApp` 管理登录启动；当系统找不到主 App 服务或代码签名被明确拒绝时，写入直接启动 App 可执行文件的用户级 LaunchAgent，兼容入口不得调用 `/usr/bin/open`。
- `NotificationService`：通过 UserNotifications 提交通知，并在非 App 运行环境下提供可验证退出状态的 `osascript` 回退。

## 外部依赖与项目假设

这个应用直接使用 Xcode 与 CoreDevice 的标准命令行接口识别、构建、签名和安装目标 iOS App。目标仓库不需要提供 iOSSignKit 专用脚本。

项目识别由多个组件共同完成：`EnvironmentValidator` 负责基础路径和工具链校验，`XcodeProjectLocator` 负责发现候选 `.xcodeproj` / `.xcworkspace`，`XcodeProjectResolver` 负责解析 Scheme、`iphoneos` App Target 与 Bundle ID。`AppConfig.xcodeprojPath` 为兼容旧配置保留原字段名，但允许保存 Project 或 Workspace 路径。关键条件包括：

- 本地能找到并执行 `xcodebuild` 与 `xcrun`；产物核验还会使用系统 `security` 和 `codesign`。
- 目标项目根目录存在，所选 Project/Workspace 位于其内部且不是符号链接逃逸路径。
- Scheme 能被 `xcodebuild -list -json` 发现，并解析出唯一匹配的 `iphoneos` App Target、Bundle ID 与 `.app` 产物。
- App Target 使用 `CODE_SIGN_STYLE=Automatic`，并提供由 10 位大写字母或数字组成的 Development Team ID。
- 固定目标设备具有可授权的完整稳定 ID，并能作为 Xcode destination 使用。

标准 Swift、SwiftUI 与 Objective-C iOS App 均可作为目标；语言不是能力边界。纯 Swift Package、Framework、Static Library 或其他不生成独立 `.app` 的 Target 不能安装到真机，必须在项目解析阶段给出明确诊断，不能伪装成可续签目标。

内置部署契约：

- 配置页选定的 Project/Workspace、Scheme、Target、Bundle ID 与最终 Build Settings 必须全部精确一致，任一不一致都在安装前失败，不回退其他候选。
- `xcodebuild` 始终使用完整设备 ID、受控 DerivedData、`-allowProvisioningUpdates` 与 `-allowProvisioningDeviceRegistration`；构建设置、Build、Install、Launch 的超时分别为 `60` 秒、`30` 分钟、`5` 分钟、`60` 秒。
- 每次部署使用 `ProvisioningProfileRefreshMode.automatic`（原始值 `auto`）或 `.force`（原始值 `force`）：`auto` 只暂时隔离过期的 Team + Bundle 精确匹配缓存，`force` 暂时隔离所有精确匹配缓存；其他 Team、Bundle 或无法安全解析的 Profile 不得移动。
- 安装前必须核验唯一 `.app` 的路径边界、Bundle ID、可执行文件、Team、代码签名、嵌入 Profile、设备 UDID、Profile 摘要与到期时间；`force` 还必须证明没有复用部署前的 Profile 摘要。
- 核验成功后先写 `prepared` 宿主回执，再调用 `xcrun devicectl device install app --device <稳定 ID>`；安装命令完整成功后立即写 `installed`，再提交 Profile 事务并尝试 Launch。
- 任一失败只在完整部署进程树已确认结束后回滚 Profile 事务；进程树不确定时保持事务 active、保留部署令牌并交给下次启动恢复，禁止并发恢复全局 Profile 缓存。
- stdout 与 stderr 各自最多保留 `8 MiB` 的有界首尾转录，但实时输出不因持久化截断而停止；截断、超时或进程树未确认必须进入类型化诊断。

设备 App 容器中的 `Library/Application Support/<候选目录名>/install-metadata.json` 是可选的首次接管有效期证据，不再是构建或安装依赖；候选名依次来自 App 名称、Bundle ID 末段、`.app` 目录名和通用目录 `App`。第一次接管既无可验证元数据、也无宿主回执的既有安装时，可以检查安装状态并执行续签，但旧安装的精确 Profile 到期时间可能在首次内置续签前未知。

## 数据存储与系统集成

- 配置文件保存在 `~/Library/Application Support/iOSSignKit/config.json`
- 运行状态保存在 `~/Library/Application Support/iOSSignKit/state.json`
- 部署日志保存在 `~/Library/Application Support/iOSSignKit/logs/`，默认受 200 份/256 MiB 的保留上限约束
- 宿主安装回执保存在 `~/Library/Application Support/iOSSignKit/Install Receipts/`，单份不超过 64 KiB，默认最多 200 份、合计不超过 8 MiB；目录权限为 `0700`、文件权限为 `0600`
- Provisioning Profile 事务备份与摘要清单保存在 `~/Library/Application Support/iOSSignKit/Provisioning Profile Backups/`，只按精确部署令牌恢复；活动事务未安全结算前不得删除或覆盖原 Profile
- 每次部署的临时工作区位于 `~/Library/Caches/iOSSignKit/Deployments/<部署令牌>/`，包含权限为 `0700` 的受控 DerivedData；只允许按完整合法令牌清理直接子目录，不递归扫描其他路径
- 启动自启优先通过 `SMAppService.mainApp` 实现；系统找不到主 App 服务或签名无效时才回退到 `~/Library/LaunchAgents/<bundle-id>.plist`，且 `ProgramArguments` 必须直接指向 App 可执行文件
- 系统通知优先通过 `UserNotifications` 提交；非 `.app` 运行环境可回退到带退出状态校验的 `osascript`
- 局域网控制默认关闭；启用时只提供 HTTP，因此只适合受信任的本地网络。配置文件只保存加盐摘要，登录会话在内存中保持 `8` 小时，一次性配对链接 `120` 秒后失效且只能使用一次；关闭服务或修改密码会清空会话与配对令牌。

## 提醒与自动刷新规则

默认配置来自 `AppConfig.default`：

- 检查频率：`5` 分钟
- 确认到期后的检查频率：`1` 分钟
- 提醒冷却时间：`24` 小时
- 默认策略：`到期时提醒`
- 默认开机自启：`false`
- 默认局域网控制：`false`

自动刷新策略支持两种模式：

- `到期时提醒`
- `到期时自动刷新`

自动化行为补充：

- 满足自动刷新条件后，会先进入 `5` 秒倒计时，再开始自动部署；倒计时期间可取消自动刷新。
- 只有已确认目标 App 存在且预计到期时，才满足自动刷新条件。
- 自动初次刷新与自动恢复显式使用 `ProvisioningProfileRefreshMode.automatic`，保持优先复用仍有效 Profile 的既有行为。
- 部署前按完整设备 ID 检查 Xcode destination；无法确认 readiness 时自动路径禁止部署，手动路径显示诊断后可继续。
- 自动刷新遇到已锁定设备时每 `30` 秒检查一次；锁态未知时每 `60` 秒检查一次且保持失败关闭；Xcode destination 仍在准备时每 `120` 秒检查一次。连续等待超过 `2` 小时后统一降为每 `300` 秒一次。
- 自动刷新等待期间，普通轮询、系统唤醒和用户“立即检查”共用同一探测循环，任一时刻至多执行一个锁态探测或部署预检；Mac 唤醒后优先在 `+5`、`+20` 秒补检。
- 自动部署提交前必须再次确认设备已解锁；只有部署进程即将真实启动时才记录自动尝试时间，锁屏等待和部署预检不得提前消耗检查冷却。
- 自动初次部署明确因 `device_preparation_required` 失败时，在重新核对设备、配置、安装实例、策略和到期条件后最多恢复重试一次；手动刷新和恢复尝试本身都不得继续递归重试。
- 自动恢复再次失败后至少退避 `10` 分钟，用户配置的检查周期更长时仍遵循更长周期。
- 同一目标、安装实例和自动刷新来源只投递一次自动解锁通知；初次失败已经发送通知时，恢复预检仍需解锁不得重复投递。手动刷新使用独立文案，不得暗示会自动继续。
- 自动刷新关键阶段会同时写入统一 OSLog 和 `state.json` 中最多 `50` 条的诊断事件环，至少覆盖到期、等待、唤醒、解锁、预检延期、恢复、部署提交、结算和通知投递结果。
- 已确认到期时，手动操作直接使用 `force` 更新签名描述文件；未到期、无法确认有效期或未确认安装状态时，必须让用户在 `force`、`auto` 和取消之间选择。
- 如果设备离线，默认不提醒也不直接部署；iOS 27 及以上的固定设备可能在已满足自动刷新条件时尝试无线配对，并要求在 iPhone 上确认信任。
- 连续两次成功检查均未找到目标 App 后，会清除该安装实例的过期推断，并停止提醒、自动刷新和自动配对；手动刷新仍需确认。
- 安装状态、过期来源和提醒冷却按“设备 ID + Bundle ID”绑定；切换任一目标时必须失效旧证据。
- 内置部署启动的外部命令使用独立进程组、精确部署令牌和持久化的只读 FD 所有权标记；正常取消采用 `TERM → KILL`，改变会话/进程组但仍继承 FD 198 的后代也会被识别清理；异常退出后的下次启动会先清理标记匹配的普通命令与部署进程，再恢复 Profile 事务与宿主回执；无法核验或终止时禁止开始新刷新。
- 如果刚完成安装，系统会给设备安装索引一个短暂缓冲期，再继续判断。

过期时间推断优先级：

1. 已安装 App 的安装元信息 `expectedExpiryAt`
2. 持久化状态中的 `lastDetectedExpiryAt`
3. 与当前设备、Bundle ID 和安装实例绑定的最近成功刷新时间 `activeInstallationSuccessAt + 7 天`

历史刷新记录中的 `lastSuccessAt` 只用于展示和审计；目标 App 已确认卸载、安装身份变化或目标切换后，不得用它恢复当前安装实例的过期推断。

## 界面与交互

- 应用以菜单栏图标常驻运行，启动时使用 `LSUIElement` 形态，不在 Dock 中常规显示。
- 左键点击菜单栏图标会打开并前置主面板；主面板已打开或最小化时也会恢复到前台。
- 右键菜单顶部提供动态双行状态摘要，命令区提供：
  `打开面板`、`重新检查`、`重新签名并安装`、`打开项目`、`退出 iOSSignKit`
- 当手动刷新需要选择 Profile 策略时，“重新签名并安装”菜单项会显示省略号。
- 主面板使用顶部命令栏、双列状态工作台和底部最近历史；设置与完整历史覆盖内容区，通过“完成”或 Escape 返回工作台。未配置时从工作台的“开始配置”进入目标设置。
- 设置页使用`目标`、`续期`、`局域网`、`通用`四个二级分类；登录启动和诊断位于`通用`，局域网服务、连接和安全配置位于`局域网`。
- `目标`、`续期`和`局域网`草稿通过底部固定保存栏统一显式提交；校验失败时必须切换到对应分类并展示错误，不能静默丢弃。恢复默认只修改续期和局域网草稿，仍需用户存储。`通用`中的登录启动直接同步系统服务并独立反馈失败，不等待该保存栏。
- “当前状态”主旅程使用统一活动反馈卡，承载检查、自动刷新倒计时、部署、自动恢复、结算结果和通用反馈；部署期间在右列常驻有界实时输出，空闲时显示已保存的续期策略，并可通过主面板浮层查看完整日志。
- “设置 → 通用”提供原生与玻璃两种界面风格，选择立即生效并通过应用偏好独立保存，不提交配置草稿或触发部署/服务重启；两种风格跟随系统深浅色，并支持减少动态效果及减少透明度。设置覆盖页关闭后保留草稿，恢复默认草稿不改变界面风格。
- “重新检查”只重新核对环境、设备与安装状态；等待自动恢复时不会因此取消恢复计划，“取消重试”才会停止待执行的自动恢复。
- “重试”可能重新发起刷新，仅当前部署明确关联的失败反馈可提供该动作；历史失败和后续通用反馈不得沿用旧结果触发部署。
- 关闭操作反馈只影响当前提示的展示，不清除持久化的历史刷新结果；进程恢复仍处于阻断状态时不得通过关闭反馈解除阻断。
- 部署过程中会实时汇总 stdout/stderr，并支持查看日志和取消当前刷新。
- 历史刷新记录支持分页加载更多日志摘要。

## 测试与当前已知限制

核心测试文件包括（非穷举）：

- `EnvironmentValidatorTests`
- `XcodeProjectResolverTests`
- `XcodeDestinationReadinessInspectorTests`
- `DeployFailureAnalyzerTests`
- `ExpiryInspectorTests`
- `ReminderPolicyTests`
- `ReminderPolicyInstalledAppTests`
- `DeviceMatcherTests`
- `DeviceMonitorTests`
- `DeviceRefreshWorkflowTests`
- `DeviceRefreshSnapshotReducerTests`
- `DeploymentPreflightWorkflowTests`
- `DeviceConnectionReducerTests`
- `DeviceDetectionRolloutControllerTests`
- `DeviceDetectionRolloutConfigurationTests`
- `DeviceMonitorLiveReadOnlyTests`
- `MenuBarViewModelDeviceDetectionSafetyTests`
- `MenuBarViewModelDeploymentVerificationTests`
- `RefreshPolicySafetyTests`
- `RefreshSessionCachesTests`
- `SystemWakeMonitorTests`
- `CommandRunnerTests`
- `DeployServiceTests`
- `StandardIOSDeploymentTests`
- `ProvisioningProfileCacheTransactionTests`
- `SignedIOSAppInspectorTests`
- `HostInstallReceiptStoreTests`
- `DeployResultTests`
- `DeployLogParserTests`
- `AppStatePersistenceTests`
- `RefreshSequenceTests`
- `SetupWizardViewModelTests`
- `RefreshStateSettlementTests`
- `WorkflowCoordinatorTests`
- `OperationActivityPresentationTests`
- `WorkspaceSizeAuditTests`
- `RefreshSchedulerTests`
- `AutomaticRefreshWaitCoordinatorTests`
- `LANControlConfigurationTests`
- `LANControlHTTPApplicationTests`
- `SettingsControlDesignTests`
- `CommandCenterVisualContractTests`
- `PackagedResourceContractTests`

覆盖重点包括：

- 通用 Project/Workspace 结构、iOS App Target 与 Bundle ID 推断
- 过期时间来源优先级与回退逻辑
- 到期判断与提醒冷却逻辑
- 设备匹配优先级
- 命令超时、取消、进程组终止、输出解码与容量上限
- 内置 Build/签名/安装链路、Profile 缓存事务、宿主回执、部署恢复、日志结算/保留策略和历史摘要
- 通知投递结果、并发刷新和目标代次隔离
- 配置页设备同步、固定设备离线展示
- 设置分类导航、显式保存、错误分类路由与局域网控制认证边界
- 到期前/到期后的独立检查频率，以及旧配置缺省迁移
- 通知附件与局域网页面静态资源的打包边界
- 操作反馈状态优先级、动作路由、历史结果隔离与自动恢复重新检查
- workspace 空间审计保持只读，不暴露被审计根目录，并正确分类 `.build`、Git 对象、`dist` 与 `runtime`
- 异步刷新测试以 `ManualRefreshScheduler` 显式推进时间，以类型化事件或任务结算接口同步；正常状态推进不得依赖真实毫秒 sleep、墙钟 deadline 或扩大 timeout

异步测试 fixture 在结束前必须取消并等待其拥有的刷新、部署预检、倒计时、自动等待、通知和辅助任务，并确认手动 scheduler 没有挂起 sleep、事件 recorder 没有等待 continuation。串行命令只作为诊断对照；涉及调度与任务生命周期的修改应先运行对应套件，再使用 `./scripts/verify-test-concurrency.sh` 验证默认并发稳定性。

当前环境下的已知限制：

- 受限沙箱中应为 SwiftPM scratch 和 clang module cache 指定可写的独立临时目录。
- 生产遗留进程发现依赖 macOS `libproc` 对固定继承 FD 的 vnode 身份核验；内置部署启动的 `xcodebuild`、`security`、`codesign` 与 `devicectl` 后代必须保留该 FD，命令夹具也不得主动关闭或隔离它。
- 涉及真机检测、`xcrun`、`devicectl`、`osascript` 的功能，天然依赖本机 Xcode 工具链、macOS 权限与已连接设备，无法仅靠静态阅读完全验证。

## 协作建议

- 理解主流程时，先从 `MenuBarViewModel` 查看编排入口，再按问题进入 `Workflows`、`State` 或对应服务；不要把已经由工作流持有的任务和取消状态重新放回 ViewModel。
- 修改项目路径发现、候选工程过滤或 Bundle ID 推断时，要同步检查 `EnvironmentValidatorTests` 与 `XcodeProjectResolverTests`。
- 修改部署链路时，要同时检查 `DeployService`、`LogStore`、`RefreshHistoryService` 与状态持久化是否仍一致。
- 修改提醒或自动刷新行为时，要同时检查 `ReminderPolicy`、`ExpiryInspector`、倒计时逻辑以及主界面状态展示。
- 修改操作反馈状态或动作时，要同步检查 `OperationActivityPresentationTests` 与 `MenuBarViewModelLockStateTests`，确保通用反馈不会继承历史部署动作，自动恢复的重新检查也不会取消恢复任务。
- 这是一个“macOS 辅助工具 + 标准 Xcode iOS App 项目”的组合：部署编排能力内建在本仓库，但实际构建、签名、设备注册和安装仍依赖本机 Xcode、Apple 签名服务状态与真机环境。
