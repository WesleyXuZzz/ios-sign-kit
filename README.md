# iOSSignKit

**iOS 个人签名续期工具**

用于在 macOS 菜单栏里检查目标 iPhone 是否已连接，并在到期时提醒或自动刷新指定 iOS App 的个人开发签名。

这个仓库本身不是 iOS App 工程，而是一个 macOS 菜单栏辅助工具。它负责监控设备、判断签名过期时间、触发提醒或自动刷新，并直接通过 Xcode 与 `devicectl` 构建、核验和安装所选 iOS App；目标项目不需要提供 iOSSignKit 专用脚本。

## 功能概览

- 菜单栏常驻展示目标 iPhone 的连接状态、签名剩余有效期、检查/倒计时/刷新进度、刷新结果与异常状态
- 通过 `xcodebuild` 识别外部 iOS 项目的 `.xcodeproj` 或 `.xcworkspace`、Scheme、iOS App Target 与 Bundle ID；多个候选时要求明确选择
- 根据安装元信息、当前安装实例的持久化过期时间，或与当前设备、Bundle ID 和安装实例绑定的最近成功刷新时间推断个人开发签名过期时间
- 支持“到期时提醒”和“到期时自动刷新”两种策略；自动刷新只会在确认目标 App 已安装且到期后启动
- 未到期、有效期未知、未确认安装状态或已确认目标 App 未安装时，手动操作会要求选择更新或优先复用现有签名描述文件
- 可选的局域网控制页支持从同一受信任网络查看设备、签名与操作进度，并在认证后重新检查或发起符合当前安全条件的续签
- 记录部署日志和历史刷新结果；默认最多保留最近 200 份、合计不超过 256 MiB（至少保留最新一份）

## 基本使用与默认设置

- 左键点击菜单栏状态项会打开并前置主面板；面板已打开或最小化时也会恢复到前台。
- 右键菜单包含动态状态摘要，以及“打开面板”“重新检查”“重新签名并安装”“打开项目”和“退出 iOSSignKit”等操作。
- 主面板只保留“状态”“历史”“设置”三个一级入口；侧栏下方另有诊断入口。
- 设置页分为“目标”“续期”“局域网”“通用”四个分类；前三类草稿通过底部“存储更改”统一显式提交，位于“通用”的登录启动开关则立即同步系统服务并单独反馈结果。

默认在签名到期前每 `5` 分钟检查一次，确认到期后每 `1` 分钟检查一次；两种检查频率都允许 `1...60` 分钟。提醒冷却时间默认为 `24` 小时、允许 `1...72` 小时；默认采用“到期时提醒”策略，不自动登录启动，也不启用局域网控制。

登录启动优先通过 macOS `SMAppService.mainApp` 注册，因此系统设置会按 `iOSSignKit` 主 App 身份显示。当系统无法发现主 App 服务或明确拒绝当前代码签名时，应用会写入直接启动 `IOSSignKit` 可执行文件的用户级 LaunchAgent；兼容配置不会调用 `/usr/bin/open`。

## 局域网控制

在“设置 > 局域网”中可显式启用本机控制页，设置访问主机、`1024...65535` 端口和至少 6 个字符的控制密码。服务运行后可以复制完整链接，或生成 `120` 秒内有效、只能使用一次的配对二维码。控制页展示当前设备、签名状态和续签阶段，并提供重新检查与重新签名安装操作。

- 服务默认关闭，并拒绝公网来源地址；它只提供 HTTP，因此只应在受信任的本地网络中使用。
- 配置文件不保存密码明文，只保存带随机盐的迭代摘要。密码登录和二维码配对生成的会话在内存中保持 `8` 小时；关闭服务或修改密码会清空已有会话和配对令牌。
- 一分钟内连续 8 次登录失败后，服务会暂时拒绝更多密码尝试。
- 远程续签复用 Mac 端既有的设备、状态与部署安全判断。当前状态需要用户选择 Profile 策略时，控制页会拒绝操作并要求回到 Mac；浏览器不能绕过预检或自行指定目标。

## 前置条件

- macOS 14 或更高版本
- 包含 Swift 6.3 工具链的 Xcode，以及对应的 Xcode Command Line Tools
- 一台已配对、可通过 Xcode 工具链访问的 iPhone
- 一个包含可构建 iOS App Target、自动签名配置和有效 Development Team 的 Xcode 项目

## 目标 iOS 项目约定

目标仓库不需要包含 `ios-device.command`、Shell 包装器或其他 iOSSignKit 专用文件。工具会在所选目录中递归发现：

- 项目目录内非依赖、非构建目录中的 `.xcodeproj`
- 项目目录内非依赖、非构建目录中的 `.xcworkspace`

发现过程会跳过隐藏目录以及 `.build`、`.swiftpm`、`DerivedData`、`dist`、`xcuserdata`、`Pods`、`Carthage`、`vendor`、`node_modules`、`.expo`、`.next` 和 `build` 等依赖或构建目录；`.xcodeproj` 内部自动生成的 `project.xcworkspace` 不会作为重复候选。

可续签目标必须同时满足：

- Scheme 能通过 `xcodebuild -list -json` 发现。
- 所选 Scheme 中存在唯一匹配的 `iphoneos` App Target，产品类型为 `com.apple.product-type.application`。
- App Target 的 Bundle ID 与配置页选择完全一致。
- `CODE_SIGN_STYLE` 为 `Automatic`，并能解析出有效的 10 位 Development Team ID。
- 项目可以针对所选真机的完整稳定 ID 构建。

标准 Swift、SwiftUI 或 Objective-C iOS App 都可以作为目标；语言不是识别条件。纯 Swift Package、Framework、Static Library 或其他不生成独立 `.app` 的 Target 无法安装到真机，因此不能作为续签目标。

内置部署固定执行以下链路：

1. 用已选择的 Project/Workspace、Scheme、完整设备 ID 和受控 DerivedData 目录读取构建设置。
2. 按 Development Team 与 Bundle ID 精确处理本机 Provisioning Profile 缓存；`auto` 只隔离已过期的精确匹配项，`force` 隔离全部精确匹配项。
3. 直接调用 `xcodebuild`，允许 Xcode 更新 Profile 和注册设备。
4. 在安装前核验生成的 `.app`、Bundle ID、可执行文件、代码签名、Team、设备授权、Profile 摘要和精确到期时间。
5. 先持久化安装前宿主回执，再用 `xcrun devicectl device install app` 安装；安装成功后立即标记回执，最后尝试启动 App。

当存在同名设备时，iOSSignKit 会拒绝部署，避免仅靠名称安装到错误真机。固定目标设备按稳定设备 ID 匹配；该 ID 当前不可用时不会回退到同名设备、唯一可用设备或其他 iPhone。

构建、Profile 解码、签名核验和安装命令均由 iOSSignKit 直接启动并实时汇总输出。内部部署令牌、进程组和只读所有权标记用于取消、超时及异常退出恢复；目标仓库无需感知或转发这些内部标识。

目标 App 可以选择写入安装元信息，但这不再是构建或安装的前置条件。工具会在设备 App 容器中依次尝试以下候选目录名：

- `devicectl` 返回的 App 名称
- Bundle ID 的最后一段
- `.app` 目录名
- 通用目录名 `App`

每个候选目录对应：

```text
Library/Application Support/<候选目录名>/install-metadata.json
```

当前支持的元数据格式如下：

```json
{
  "schemaVersion": 1,
  "recordedAt": "2026-07-30T08:00:00Z",
  "bundleIdentifier": "com.example.App",
  "shortVersion": "1.0",
  "buildVersion": "1",
  "expectedExpiryAt": "2026-08-06T08:00:00Z",
  "profileSource": "embedded_mobileprovision"
}
```

`recordedAt` 和可选的 `expectedExpiryAt` 使用 ISO 8601 时间。Bundle ID、短版本和 Build 必须与当前安装实例完全一致；`recordedAt` 最多允许比当前时间快 `5` 分钟，`expectedExpiryAt` 不得早于 `recordedAt` 超过 `5` 分钟，也不得晚于它超过 `8` 天。`profileSource` 必须为不超过 `256` UTF-8 字节的非空文本，且不能包含控制字符。无法验证的元数据不会覆盖已知状态。

第一次接管一个已经安装、但既没有可验证安装元信息、也没有 iOSSignKit 宿主回执的 App 时，系统可以确认安装状态并执行续签，但可能暂时无法得到旧安装的精确 Profile 到期时间。第一次内置续签完成后，iOSSignKit 会从已核验产物记录精确到期时间，后续检查不要求目标 App 写入专用文件。

## 自动化边界

- 设备离线时不会提醒或直接部署。
- iOS 27 及以上的固定设备在到期且满足自动刷新条件时，可能自动尝试同一局域网无线配对；iPhone 可能要求解锁并确认信任或开启开发者模式。
- 自动刷新只在已确认目标 App 存在且预计到期时进入 5 秒倒计时；连续两次确认 App 未安装后会停止提醒、自动刷新和自动配对。
- 自动刷新和自动恢复显式使用 `auto`，优先复用仍有效的 Profile；只有已确认到期的手动操作会直接使用 `force`。
- 部署前会按完整设备 ID 检查 Xcode destination。检查结果不确定时自动刷新会停止，手动刷新会显示诊断后允许继续。
- 如果自动部署明确因目标 iPhone 尚未完成 Xcode 设备准备而失败，解锁提示只发送一次，并在重新核对设备、目标配置、安装实例、策略和到期条件后最多恢复重试一次；恢复尝试不会递归重试。
- 安装状态、过期推断和提醒冷却同时绑定设备 ID 与 Bundle ID；切换设备或目标 App 后不会沿用旧目标证据。
- “最近成功刷新时间 + 7 天”的兜底仅属于当前安装实例；历史刷新记录不会在 App 已确认卸载或安装实例变化后重新成为有效期证据。
- 已确认到期时，手动操作会直接更新签名描述文件并重新安装；未到期、有效期未知、未确认安装状态或已确认目标 App 未安装时，会要求选择更新描述文件、优先复用现有描述文件或取消。
- 应用异常退出后会在下次启动时先校验并终止归属可证明的遗留部署进程，再按精确部署令牌清理构建工作区、恢复 Provisioning Profile 缓存并核对宿主安装回执。进程、Profile 或回执无法安全确认时会保留令牌、阻止新续签并显示诊断；单纯的工作区清理失败只记录警告。

## 本地开发

```bash
cd ios-sign-kit
swift build
swift test
open Package.swift
```

`Package.swift` 用 Xcode 打开后可以直接运行 `IOSSignKit`。

### 项目草稿工作区

开发方案、设计稿及其配套素材统一保存在根目录 `project-drafts/` 中。每项工作可按主题新建独立子目录和文件，便于在实现前讨论和迭代。

除用于保留目录的 `.gitkeep` 外，该目录内容均被 Git 忽略，且不作为项目长期事实源。需要长期保留的结论应在确认后归并到代码、测试、`AGENTS.md`、`README.md` 或现有的 `docs/architecture.md`、`docs/ui-guidelines.md` 中，不应强制提交原始工作稿。

## 公开开发与私有镜像

GitHub 的 `master` 是项目唯一的日常开发事实源。私有仓库只保存与 GitHub 相同提交 OID 的镜像；迁移前的私有历史保存在独立只读备份中，不参与后续日常推送。所有 Git 跟踪文件都会进入公开历史，不再通过路径清单生成另一棵公开提交树。

初次克隆公开仓库后，`origin` 应指向 GitHub；需要维护私有镜像时，另行添加名为 `private` 的 remote：

```bash
git clone https://github.com/WesleyXuZzz/ios-sign-kit.git
cd ios-sign-kit
git config user.email '<YOUR_GITHUB_NOREPLY_EMAIL>'
git remote add private <PRIVATE_MIRROR_URL>
```

提交前先运行只读公开源码检查：

```bash
./scripts/verify-public-source.sh
```

检查器要求工作区干净、仓库具有完整历史，并扫描 `HEAD` 及其全部可达提交；shallow 仓库、Git replacement refs 和 legacy grafts 都会失败关闭。每个提交的作者与提交者都必须使用 GitHub noreply 邮箱；提交消息与文件内容都会接受凭据、本机用户路径、私有远端和已退出流程标记检查。路径扩展名按大小写不敏感规则拒绝私钥、签名材料以及 `.app`、`.dmg`、`dist/` 等非源码发布内容；根目录必须保留许可证、资产授权和安全策略文件。自动规则不能代替首次发布与重要变更时的人工审查。

每次需要把 `master` 推送到两端时，先预检，再执行正式推送：

```bash
./scripts/push-source-mirrors.sh --dry-run
./scripts/push-source-mirrors.sh
```

推送脚本具有以下边界：

- 固定从本地 `master` 推送到 GitHub `origin/master` 和私有 `private/master`，每个 remote 必须且只能有一个 fetch URL 和一个实际 push URL；`origin` 的 fetch 与 push URL 都必须在协议、主机、默认端口和仓库路径归一化后指向本项目的 GitHub 仓库，`private` 不得以等价 URL 再次指向同一公开仓库。任何 `url.*.insteadOf` 或 `pushInsteadOf` 重写都会在网络访问前被拒绝。
- 在任何实际写入前，对两端执行 fast-forward dry-run；任一预检失败时两端都不推送。
- 脚本在公开源码检查前冻结本地 `master` OID 和两端实际 push URL，检查、refspec、网络目标与远端复核始终使用这些冻结值；网络 Git 子进程忽略仓库、全局和系统 Git 配置并禁用本地 hook，显式禁止跟随标签和递归推送子模块，只允许写入目标 `master` ref。分支、`master`、工作区或 remote URL 配置在运行期间发生变化时立即停止。
- 预检通过后先更新私有镜像，再更新 GitHub，最后通过两端实际 push URL 重新读取 OID；只有两端都等于已验证的本地提交才返回成功。
- 两台 Git 服务器之间不存在原子事务。GitHub 阶段失败时，私有镜像可能已经更新；脚本会返回非零并显示两端状态，修复远端问题后应重试。
- 脚本从不执行 force、pull、fetch、merge、rebase，也不会创建或修改 remote。不得用强制推送绕过分叉或非 fast-forward 诊断。

普通 `git push` 默认只保证一个 remote，不作为项目的双镜像发布入口。

## 打包应用

默认生成 release `.app`：

```bash
cd ios-sign-kit
./scripts/build-app.sh
open dist/iOSSignKit.app
```

需要生成可拖拽到“应用程序”安装的 release DMG 时，必须显式传入 `dmg`：

```bash
cd ios-sign-kit
./scripts/build-app.sh dmg
open dist/iOSSignKit.dmg
```

`app` 参数仍可显式使用，例如 `./scripts/build-app.sh app`。日常功能验证直接执行默认命令即可复用 SwiftPM 和 App Icon 缓存并跳过 DMG 创建；只有正式 release 验收时才显式生成完整 DMG。

将已经生成的正式 App 安装到本机“应用程序”目录：

```bash
./scripts/install-app.sh
```

脚本只处理 `dist/iOSSignKit.app`，不会自动构建、启动应用或请求提权。安装前会核验 Bundle ID、可执行文件和代码签名，并拒绝替换仍在运行的 iOSSignKit。已有安装会先移动到废纸篓；安装中途失败时，脚本会尝试恢复 `dist` 产物和原安装。只检查、不移动文件时可执行 `./scripts/install-app.sh --dry-run`。

需要测量项目级冷构建时，显式传入 `--clean`。脚本会在取得打包锁后递归删除当前项目的 `.build`，同时清除 SwiftPM 构建产物与 App Icon 缓存，但不会删除 `dist`、`.swiftpm` 或全局 SwiftPM/Xcode 缓存：

```bash
cd ios-sign-kit
./scripts/build-app.sh --clean
./scripts/build-app.sh
```

第一条命令用于测量冷构建，第二条用于测量热缓存构建；缓存清理耗时会单独显示，并计入第一条命令的总耗时。`--clean` 也可以与 `dmg` 或 `--debug` 组合使用。

生成调试 `.app`：

```bash
cd ios-sign-kit
./scripts/build-app.sh --debug
open dist/iOSSignKit-Debug.app
```

生成调试 DMG：

```bash
cd ios-sign-kit
./scripts/build-app.sh dmg --debug
open dist/iOSSignKit-Debug.dmg
```

脚本会自动完成这些事情：

- 运行 `swift build`
- release 构建默认使用 Swift `-Osize`，在保留优化的同时优先缩小可执行文件
- release 构建默认使用 `-debug-info-format none`，避免生成不会随 App 发布的 DWARF/dSYM；需要保留 release 符号用于崩溃分析时，可执行 `RELEASE_DEBUG_INFO_FORMAT=dwarf ./scripts/build-app.sh`
- 组装标准 macOS `.app` Bundle
- 将根目录 `AppIcon.icon` 编译为现代 `Assets.car`，并按输入与 Xcode 版本复用 `.build/generated-app-icon` 缓存
- 在 release 构建中裁剪本地符号；debug 构建保留符号
- 写入 `Info.plist`
- 打开 `LSUIElement`，让它保持菜单栏应用形态
- 默认做一次 ad-hoc `codesign`；显式提供 `IOS_SIGN_KIT_CODE_SIGN_IDENTITY` 时使用对应身份签名
- 按需生成 APFS + LZFSE 压缩、包含 `.app` 和“应用程序”快捷入口的 DMG
- 输出 Swift 构建、图标处理、App 组装、DMG 创建的耗时与产物大小

SwiftPM 运行时资源中不保存 App Icon 副本；正式应用图标只来自根目录 `AppIcon.icon`。日常重复打包不要清理 `.build`，否则会丢失 SwiftPM 与 App Icon 的增量缓存。

正式 Bundle ID 固定为 `com.xuzw.iossignkit`。展示名、可执行名、Bundle ID、版本号和最低 macOS 版本统一来自 `config/release-metadata.json`；release 构建不接受 `BUNDLE_IDENTIFIER` 或 `BUNDLE_VERSION` 环境覆盖。元数据缺失、内容非法或发生覆盖尝试时会在 Swift 构建前失败。

从旧 Bundle ID 或 `/usr/bin/open` LaunchAgent 升级时，应用只会在旧配置是普通文件、Label 精确匹配且启动入口可核验时迁移到 `SMAppService.mainApp`；无法证明归属的文件会保留并给出手动处理提示。macOS 会把新 Bundle ID 视为新的通知主体，安装运行验收时需要重新确认通知权限。

需要用已有开发证书构建可由 Service Management 识别的本地 App 时，显式传入签名身份：

```bash
IOS_SIGN_KIT_CODE_SIGN_IDENTITY="Apple Development: Developer Name (TEAMID)" ./scripts/build-app.sh
```

签名身份只通过当前命令环境提供，不写入项目元数据；不传时继续生成 ad-hoc 签名 App。

release 默认不生成调试信息；需要保留 DWARF/dSYM 时可显式开启：

```bash
RELEASE_DEBUG_INFO_FORMAT=dwarf ./scripts/build-app.sh
```

`RELEASE_DEBUG_INFO_FORMAT` 只接受 `none` 或 `dwarf`，不会影响 `--debug` 构建。

完整 release 产物验收前需要显式生成 DMG：

```bash
./scripts/build-app.sh dmg
./scripts/verify-release-artifacts.sh
```

需要查看项目、构建缓存、Git 对象和本地产物的磁盘占用时，可以运行只读审计：

```bash
./scripts/audit-workspace-size.sh
```

该脚本只报告 `.build`、Git 对象、`dist` 遗留项和 `runtime` 大项，不会自动删除、压缩或修改文件。

## 分发说明

iOSSignKit 的 GitHub 初版仅发布仓库源码，不提供官方预编译 `.app`、`.dmg`，也不在 GitHub Releases 中附加二进制产物。下述打包步骤仅供使用者从源码进行本地构建与自用验收。

`scripts/build-app.sh` 默认生成 `.app`，显式传入 `dmg` 时才生成 DMG。默认 App 使用 ad-hoc 签名，也可以通过 `IOS_SIGN_KIT_CODE_SIGN_IDENTITY` 使用现有签名身份；DMG 本身仍未签名、未公证，因此默认产物只适合本地测试和自用。如果要把 DMG 或 `.app` 作为 GitHub Release 或其他公开渠道分发，应使用 Developer ID 证书签名，并完成 Apple notarization，否则其他用户首次打开时可能会遇到 Gatekeeper 拦截。

## 建议重点测试的交互

- 左键点击菜单栏状态项是否能打开或恢复主面板
- 右键菜单的动态状态摘要和“重新检查 / 重新签名并安装 / 打开项目 / 退出 iOSSignKit”是否可用
- 设置页四个分类是否支持鼠标与左右方向键切换，校验失败时是否跳转并标记对应分类
- 登录自启是否能立即同步或反馈失败，到期前/到期后检查频率和局域网控制草稿是否能显式存储
- 三个一级入口、诊断入口、部署实时输出、日志浮层和历史详情之间的导航是否稳定
- 局域网控制的密码登录、一次性二维码、状态刷新和受控续签是否符合预期
- 刷新后重新点击菜单栏状态项，面板是否仍稳定

## 在另一台 Mac 复用

前提：

- 已安装 Xcode
- 已安装命令行工具
- 本地已存在需要刷新的 iOS 工程

执行：

```bash
git clone https://github.com/WesleyXuZzz/ios-sign-kit.git
cd ios-sign-kit
./scripts/build-app.sh dmg
open dist/iOSSignKit.dmg
```

首次运行如果被 Gatekeeper 拦截，可以在“系统设置 > 隐私与安全性”里允许打开，或者右键 `.app` 后选择“打开”。

## 许可证、资产与安全

项目代码、文档及 [视觉资产清单](ASSET_PROVENANCE.md) 中明确列出的项目自有素材均采用 [MIT License](LICENSE)。

安全边界、已知限制和私密漏洞报告方式见 [SECURITY.md](SECURITY.md)。请勿在公开 Issue、Discussion 或 Pull Request 中披露尚未修复的漏洞或敏感日志。
