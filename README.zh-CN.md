# ClickMate

[English README](README.md)

ClickMate, 中文名“右键大师”，是一个原生 macOS Finder 右键菜单增强工具。它基于 SwiftUI、AppKit 和 Finder Sync extension 构建，可以在 Finder 右键菜单中加入可配置的 `ClickMate` 子菜单，让常用文件和文件夹操作更顺手。

## 功能特性

- 支持选中文件、选中文件夹，以及已监控文件夹空白区域的 Finder 右键菜单。
- 新建文件模板：文本、Markdown、JSON、CSV、HTML、CSS、JavaScript、Swift、Python，以及自定义扩展名。
- 复制辅助：POSIX 路径、文件 URL、Shell 转义路径、文件名、基础文件名、扩展名、父级文件夹路径。
- 打开辅助：Terminal、iTerm2、VS Code、Cursor、BBEdit、Sublime Text，以及自定义固定应用。
- 哈希计算：SHA-256、SHA-1、MD5。
- 文件工具：显示父级文件夹、带时间戳复制、创建替身、移动到新文件夹、压缩。
- 高级工具：查看元数据、图片尺寸、切换隐藏文件显示。
- 设置界面：菜单布局、文件模板、应用检测、固定应用、监控文件夹。

## 环境要求

- macOS 14.0 或更高版本。
- Xcode 以及 macOS 开发工具。
- 本地无签名开发构建不强制要求 Apple Development team；如果要完整签名并分发 Finder extension，则需要配置开发团队和相关 entitlement。

## 构建

用 Xcode 打开项目：

```sh
open ClickMate.xcodeproj
```

也可以使用命令行构建：

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS'
```

本地无签名验证时，可以显式关闭代码签名：

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Debug 配置面向本地开发。Release 构建保留用于正式分发签名的 entitlement 文件。

## 本地运行

1. 在 Xcode 中打开 `ClickMate.xcodeproj`。
2. 选择 `ClickMate` scheme。
3. 如果需要完整可用的已签名 Finder extension，请为 app 和 Finder extension targets 设置 development team，并启用 App Group entitlement。
4. 运行 app。
5. 打开系统设置，在 Extensions 中启用 ClickMate Finder extension。
6. 如果菜单没有立即出现，可以重启 Finder：

```sh
killall Finder
```

然后在 Desktop、Documents、Downloads，或在 ClickMate 的 Permissions 页面添加的文件夹中右键测试。

## 打包未签名 DMG

仓库提供了本地未签名 DMG 打包脚本：

```sh
Scripts/package_unsigned_dmg.sh
```

该 DMG 没有经过 Developer ID 签名，也没有 notarized。在其他机器上运行时，macOS Gatekeeper 可能会拦截应用；接收者需要明确信任该应用，或在复制到 `/Applications` 后移除 quarantine 属性。

## 贡献

欢迎贡献。请尽量保持改动聚焦，遵循项目现有 Swift 和 SwiftUI 风格；如果修改应用逻辑，请使用 `xcodebuild test` 验证相关行为。

## 许可证

ClickMate 使用 [MIT License](LICENSE) 开源。
