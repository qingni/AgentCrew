
# 修复文档：Pipeline 执行 CLI 命令报 "command not found" 错误

## 问题日期

2026-03-10

## 问题现象

在 AICliTools 应用中运行 Pipeline 时，步骤执行失败，报错信息如下：

```
Step failed (exit code 127): zsh:1: command not found: codex-internal
```

执行日志显示：

```
[Original Command]
codex-internal exec --sandbox workspace-write --skip-git-repo-check {{prompt}}

[Executed Command]
codex-internal exec --sandbox workspace-write --skip-git-repo-check '参考agent React的原理, 实现一个agent'
```

**exit code 127** 表示操作系统无法在 `PATH` 中找到要执行的命令。

## 问题原因

### 根因：macOS GUI 应用不继承终端 Shell 的环境变量

在 macOS 系统中，**GUI 应用程序**（通过 Xcode 构建运行、或从 Finder/Dock 启动）与**终端应用程序**拥有不同的环境变量：

| 启动方式 | PATH 包含的路径 |
|---------|---------------|
| 终端 (Terminal/iTerm) | 系统路径 + `.zshrc`/`.zprofile` 中通过 nvm/pyenv/homebrew 等注入的路径 |
| GUI 应用 (Xcode/Finder) | 仅系统基础路径：`/usr/bin:/bin:/usr/sbin:/sbin` 等 |

本项目中，`codex-internal` 命令安装在 nvm 管理的 Node.js 目录下：

```
~/.nvm/versions/node/v18.20.5/bin/codex-internal
```

这个路径是通过 `~/.zshrc` 中的 nvm 初始化脚本注入到终端的 `PATH` 环境变量中的。但当 AICliTools 作为 GUI 应用启动时，`Process` 对象拿到的 `PATH` **不包含**这些路径，因此报 `command not found`。

### 技术细节

macOS 的 `launchd` 为 GUI 应用提供的默认环境变量非常精简。在终端中通过 `~/.zshrc` 等配置文件设置的环境变量（包括 nvm、pyenv、rbenv、homebrew 等工具链的路径），**不会**传递给 GUI 进程。

应用中原有的 `CLIRunner` 实现：

```swift
// 修复前的代码
if let env = environment {
    var merged = ProcessInfo.processInfo.environment
    merged.merge(env) { _, new in new }
    process.environment = merged
}
```

这段代码只是将调用方传入的额外环境变量与当前进程的环境变量合并，但当前进程（GUI 应用）的 `PATH` 本身就不完整，所以合并后依然找不到命令。

## 解决方案

### 修改文件

`Sources/AICliTools/Services/CLIRunner.swift`

### 修改内容

在 `CLIRunner` 类中新增三个核心组件：

#### 1. `userShellPATH` — 静态属性，一次性获取用户 Shell 的完整 PATH

```swift
private static let userShellPATH: String? = {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    // -l: 作为登录 shell 启动，加载 .zprofile/.zshrc 等配置
    // -i: 交互模式（某些配置只在交互模式下生效）
    // -c: 执行命令后退出
    proc.arguments = ["-l", "-i", "-c", "echo $PATH"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe() // 丢弃 stderr
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    } catch {
        return nil
    }
}()
```

**工作原理**：应用启动时，通过 `$SHELL -l -i -c "echo $PATH"` 启动一个用户的登录 Shell 子进程，该子进程会加载 `.zshrc`、`.zprofile` 等所有配置文件，然后输出完整的 `PATH`。由于使用 `static let`，此操作只在首次访问时执行一次。

#### 2. `buildEnvironment` — 构建增强后的环境变量

```swift
private static func buildEnvironment(extra: [String: String]?) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if let shellPath = userShellPATH {
        let currentPath = env["PATH"] ?? ""
        let merged = mergePaths(primary: shellPath, secondary: currentPath)
        env["PATH"] = merged
    }
    if let extra = extra {
        env.merge(extra) { _, new in new }
    }
    return env
}
```

**工作原理**：将从 Shell 中获取的完整 PATH 与 GUI 应用自身的 PATH 合并，Shell PATH 优先级更高。

#### 3. `mergePaths` — 智能合并两个 PATH 字符串

```swift
private static func mergePaths(primary: String, secondary: String) -> String {
    var seen = Set<String>()
    var result: [String] = []
    for path in (primary + ":" + secondary).split(separator: ":") {
        let p = String(path)
        if !p.isEmpty && seen.insert(p).inserted {
            result.append(p)
        }
    }
    return result.joined(separator: ":")
}
```

**工作原理**：将 primary（Shell PATH）和 secondary（GUI PATH）拼接后去重，保持 primary 的优先顺序。

#### 4. 修改 `run` 方法中的环境变量设置

```swift
// 修复前
if let env = environment {
    var merged = ProcessInfo.processInfo.environment
    merged.merge(env) { _, new in new }
    process.environment = merged
}

// 修复后（始终注入增强的 PATH）
process.environment = CLIRunner.buildEnvironment(extra: environment)
```

**关键变化**：不再仅在传入额外环境变量时才设置 `process.environment`，而是**始终**使用增强后的环境变量，确保每次命令执行都能找到用户安装的工具。

## 影响范围

此修复对所有 Runner 生效，包括：

| Runner | CLI 命令 | 受益 |
|--------|---------|------|
| CodexRunner | `codex-internal` | ✅ 可找到 nvm 下安装的 codex-internal |
| ClaudeRunner | `claude` | ✅ 可找到 npm 全局安装的 claude |
| CursorRunner | `cursor-agent` / `agent` | ✅ 可找到各类包管理器安装的命令 |

## 验证方法

1. 在 Xcode 中 Build & Run 应用
2. 创建一个使用 Codex 工具的 Pipeline Step
3. 执行 Pipeline，确认步骤不再报 `command not found` 错误
4. 分别测试 Codex、Claude、Cursor 三种工具的命令执行

## 备注

- 如果用户使用的是 `bash` 而非 `zsh`，此方案同样适用，因为代码通过 `$SHELL` 环境变量动态获取用户的默认 Shell
- `userShellPATH` 使用 `static let` 延迟初始化，只在首次使用时执行一次 Shell 子进程，不会影响应用启动性能
- 如果 Shell 子进程执行失败（极端情况），会优雅降级回 GUI 应用自身的环境变量
