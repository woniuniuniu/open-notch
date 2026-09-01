# OPEN BAR / 若栏 · 1.0 beta

OPEN BAR （中文名：若栏）是一个原生、开源的 macOS 菜单栏管理器。这是一次完整的 1.0 beta 结构重写，旧 `open-notch` 代码不是它的结构基础。

## 能力

- 显示、隐藏、始终隐藏三条紧凑轨道：图标无文字卡片，悬停显示完整名称；图标顺序始终跟随真实菜单栏从左到右的顺序，拖拽只负责跨区显示策略。
- 稳定身份解析：OneDrive 等标题和窗口会变的项目使用 Bundle ID 级身份。
- 布局守护：只有连续两次确认偏移后才修复，并设有冷却期。
- 新菜单栏项目：应用启动或菜单栏项目出现时自动登记，默认放入“显示”，并按 macOS 当前真实顺序插入；已经记录但暂未运行的 App 会保留为离线项目，启动后原位更新。
- 状态栏向下箭头会打开紧凑半透明快捷栏，可直接搜索并查看全部项目。
- AI 一键排位：用户主动点击后，会结合 Mac 型号、内置屏幕物理尺寸、分辨率和右侧可用宽度生成方案；远端不可用时会明确标记并回退到本地方案。
- AI 方案会同时决定三分区与顺序，先显示 Before / After 审核，只有用户确认后才应用。
- 中英文、浅色/深色、登录启动、状态栏快捷菜单、可导出诊断。
- 策略保存为可读、可版本化的 `policies.json`，损坏文件会自动隔离。

## macOS 26 / 27 架构

```text
SwiftUI UI -> AppModel -> MenuBarBackend
                            |- LegacyMenuBarBackend (macOS 14-26)
                            |  WindowServer + AX + two section boundaries
                            |  targeted drag for section placement, never horizontal reorder or global HID posting
                            `- MenuBarAgentBackend (macOS 27+)
                               AX inventory + preference slots + assessment assertion
```

UI、策略、AI 排位和守护状态机中没有散落的系统版本判断。macOS 27 的运行时私有符号全部收口在单独适配器中，符号不存在时只降级功能，不会阻止 App 启动。

macOS 27 当前按拥有者 Bundle ID 应用显示限制，因此同一 App 创建的多个菜单栏项会一起显示或隐藏。界面会明确显示这一系统边界。

## 构建

需要 Apple silicon（M 芯片）Mac、macOS 14+ 和 Apple Command Line Tools。Release 包只构建 arm64：

```zsh
./build.sh
```

产物：

- `build/OPEN-BAR-1.0.0-beta.zip`

`build.sh` 先运行核心单元测试，然后在系统临时目录中构建 arm64、生成 `.icns`、组装并验证签名，最后对 ZIP 解压复验。仓库位于云同步目录时，Finder/File Provider 会给 `.app` 写入额外元数据并破坏严格签名，因此构建目录只保留 ZIP，不保留可运行的 App。

本地调试默认使用 ad-hoc 签名，只适合当前 Mac。对外发布必须设置 `OPEN_BAR_SIGN_IDENTITY` 为 Developer ID Application 证书，并完成 Apple notarization；否则其他用户可能被 Gatekeeper 拦截，即使程序本身可以运行。

## 首次运行

1. 运行 `./install-local.sh`，它会停止并删除旧 OPEN BAR / Open Notch App，再将稳定签名的唯一版本安装到 `~/Applications`。不要直接从云同步或仓库目录授权。
2. 启动 `~/Applications/OPEN BAR.app`。
3. 在“系统设置 > 隐私与安全性 > 辅助功能”允许 OPEN BAR。回到 App 后会自动检测生效。

不建议与 Bartender、Ice 或其他菜单栏管理器同时运行，它们会竞争同一组系统状态。

## 开发

```zsh
swift run OpenBarCoreChecks
swift build
```

- `Sources/OpenBarCore`：无 UI 的身份、策略、守护和 AI 排位引擎。
- `Sources/OpenBar/Application`：App 生命周期和单一应用状态。
- `Sources/OpenBar/Infrastructure`：系统扫描、macOS 适配器、持久化和诊断。
- `Sources/OpenBar/UI`：原生 SwiftUI 工作界面。
- `Tests/OpenBarCoreChecks`：无外部测试框架的稳定身份、双样本守护、布局和策略检查。

## 隐私

菜单栏扫描、布局策略、守护和诊断仍默认在本机完成。只有用户主动点击“AI 智能整理”时，OPEN BAR 才会把菜单栏项的名称、Bundle ID、当前分区，以及 Mac 型号与屏幕尺寸发送给推荐服务。不发送文件、菜单内容、序列号或用户输入；应用不含账号和分析 SDK。
