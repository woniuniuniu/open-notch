# Open Notch（开放刘海）

Open Notch 是一个开源的 macOS 菜单栏整理工具，重点提供对 OneDrive 动态菜单栏图标的持续固定。设置窗口使用原生 AppKit 与 SwiftUI，状态栏菜单提供展开、扫描、重启、设置和退出入口。

应用默认使用英语，可在“通用”中切换为简体中文；同一处可以选择浅色或深色外观，设置窗口与状态栏菜单会同步更新。

## 使用要求

- Apple 芯片 Mac
- macOS 14 或更高版本（支持 macOS 26）
- 在“系统设置 > 隐私与安全性 > 辅助功能”中允许 Open Notch

请不要同时运行 Ice、Bartender 或其他菜单栏整理工具。Open Notch 与 Apple、Bartender、Ice、Microsoft、OneDrive 均无官方关联。

## 本地构建

项目使用 Apple Command Line Tools，不要求完整 Xcode：

```zsh
./build.sh
```

输出为 `build/Open Notch.app` 和 `build/Open Notch.zip`。本地构建使用 ad-hoc 签名，正式分发还需要 Developer ID 签名与 notarization。

## 工作方式

macOS 没有公开的跨进程菜单栏排序 API。只有在确认布局偏差后，Open Notch 才会通过辅助功能执行一次有限的 Command-拖动；只读扫描和持续监测不会注入鼠标移动。macOS 26 中 OneDrive 可能由控制中心托管，且临时失去辅助功能语义，Open Notch 会结合 OneDrive 的 Bundle Identifier、实时几何位置和本机持久绑定恢复身份。

## 许可

Open Notch 使用 GNU GPL v3.0，详见 [`LICENSE`](LICENSE)。托管状态栏图标事件路由兼容层源自 [Ice](https://github.com/jordanbaird/Ice)，同样遵循 GPL-3.0；归属范围见 [`NOTICE.md`](NOTICE.md)。
