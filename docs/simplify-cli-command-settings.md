
# 优化文档：简化 CLI 命令配置体系

## 优化日期

2026-03-12

## 问题现象

原有的命令配置体系存在冗余，用户需要在多处重复配置和理解 CLI 命令：

1. **Settings 界面**：暴露了 4 个完整的命令编辑框（Cursor / Codex / Claude / Planner），用户需要理解命令语法才能使用
2. **每个 Step**：默认显示完整的 CLI 命令文本，新建 Step 时会硬编码一条命令到 `command` 字段
3. **AI 生成的 Pipeline**：同样为每个 Step 硬编码了完整的命令字符串

用户实际只关心两件事：**用哪种 CLI 环境**（Open Source vs Internal）和**偶尔对某个 Step 做命令微调**。

## 设计思路

参考 GitHub Actions / GitLab CI 的设计理念——全局定义 runner 环境，step 级别只选工具类型，高级用户可覆盖命令。

### 三层架构

| 层级 | 职责 | 用户操作 |
|------|------|---------|
| 全局环境 | 决定使用 Open Source 还是 Internal 的 CLI | Settings 中切换一个下拉 |
| Step 工具选择 | 每个 Step 选 Tool（Codex/Claude/Cursor）+ 可选 Model | 下拉选择 + 输入框 |
| 高级覆盖 | 完全自定义命令（折叠隐藏） | 展开 Advanced 区域编辑 |

### 核心行为

- 切换全局环境后，所有**未自定义命令**的 Step 自动跟随新环境
- 已在 Advanced 里填了自定义命令的 Step **保持不变**，不受环境切换影响
- 命令在运行时根据「环境 + Tool + Model」动态生成，不再持久化到 Step 的 `command` 字段

## 修改文件

### 1. `Sources/AgentCrew/Views/ContentView.swift` — Settings 界面

**修改前：**

```swift
// SettingsSheet 包含 4 个命令编辑框 + parseCommand 解析逻辑
@State private var cursorCommand = ""
@State private var codexCommand = ""
@State private var claudeCommand = ""
@State private var plannerCommand = ""

// 用户编辑后需要手动 Save Commands，内部解析为 ToolCLIConfig
private func parseCommand(_ command: String, base: ToolCLIConfig) -> ToolCLIConfig { ... }
private func saveCommandsToProfile() { ... }
```

**修改后：**

```swift
// SettingsSheet 只有环境切换 + CLI 检测状态
GroupBox("CLI Environment") {
    // 环境下拉：Default (Open Source) / Internal
    Picker("", selection: ...) { ... }
    // 自动检测已安装的 CLI 工具
    LazyVGrid { ForEach(detectionResults) { ... } }
    // 显示各工具当前使用的 executable
    ForEach(ToolType.allCases) { tool in cliToolRow(tool) }
}
```

**删除：** `parseCommand`、`saveCommandsToProfile`、`loadCommandsFromProfile`、4 个命令状态变量、`commandField` 构建方法。

### 2. `Sources/AgentCrew/Views/StepDetailView.swift` — Step 配置

**修改前：**

```swift
// Command 字段直接显示在 Configuration section 中
TextEditor(text: $command)  // 显眼的大文本框
```

**修改后：**

```swift
// 新增 Tool 选择器和 Model 输入框
Picker("", selection: $selectedTool) {
    ForEach(ToolType.allCases) { tool in ... }
}
TextField("Leave empty for default", text: $modelOverride)

// Command 移入折叠区域
DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
    TextEditor(text: $command)  // 自定义命令覆盖
}

// 新增 Resolved Command 预览 + 复制按钮
HStack {
    Text("Resolved Command")
    Button { NSPasteboard.general.setString(preview, forType: .string) } label: {
        Label(showCopied ? "Copied" : "Copy", systemImage: ...)
    }
}
Text(preview)  // 实时显示最终命令
```

**新增字段：** `selectedTool`、`modelOverride`、`showAdvanced`、`showCopied`。

**isDirty 逻辑变更：** 直接比较 `step.command` 而非 `effectiveCommand(profile:)`，避免切换环境误触 dirty 状态。

### 3. `Sources/AgentCrew/Views/PipelineEditorView.swift` — Step 列表

**修改前：**

```swift
// StepRow 显示命令文本作为副标题
if step.hasCustomCommand {
    Text(step.effectiveCommand(profile: profile).prefix(60))
}
// Add Step 硬编码命令
let step = PipelineStep(
    name: "Step \(stepNumber)",
    command: ToolType.codex.defaultCommandTemplate(profile: profile),
    prompt: ""
)
```

**修改后：**

```swift
// StepRow 显示 Tool badge + Model + prompt 预览
HStack {
    Text(step.name)
    Text(tool.displayName)  // 带颜色的 Capsule badge
    if let model = step.model { Text(model) }
}
// Add Step 不再硬编码命令
let step = PipelineStep(name: "Step \(stepNumber)", prompt: "")
```

### 4. `Sources/AgentCrew/ViewModels/AppViewModel.swift` — Demo 模板

**修改前：**

```swift
let profile = CLIProfileManager.shared.activeProfile
let codingA = PipelineStep(
    name: "Implement feature A",
    command: ToolType.codex.defaultCommandTemplate(profile: profile),
    prompt: "...", tool: .codex
)
```

**修改后：**

```swift
let codingA = PipelineStep(
    name: "Implement feature A",
    prompt: "...", tool: .codex
)
```

不再引用 `CLIProfileManager`，不再硬编码命令。

### 5. `Sources/AgentCrew/Models/AutoPlannerModels.swift` — AI 生成 Pipeline

**修改前：**

```swift
func toPipeline(workingDirectory: String, profile: CLIProfile) -> Pipeline {
    let step = PipelineStep(
        command: resolvedTool.defaultCommandTemplate(model: ..., profile: profile), ...
    )
}
```

**修改后：**

```swift
func toPipeline(workingDirectory: String) -> Pipeline {
    let step = PipelineStep(
        prompt: ..., tool: resolvedTool, model: ...,
    )
}
```

移除 `profile` 参数，Step 不再持久化命令。

### 6. `Sources/AgentCrew/Services/AIPlanner.swift` — 调用处

```swift
// 修改前
return plan.toPipeline(workingDirectory: request.workingDirectory, profile: profile)

// 修改后
return plan.toPipeline(workingDirectory: request.workingDirectory)
```

### 7. `Sources/AgentCrew/Views/CLIProfileSetupView.swift` — 首次启动

简化标题为 "CLI Environment"，按钮文案从 "Apply" 改为 "Continue"，整体更简洁。核心的自动检测 + 推荐选择逻辑保持不变。

## 未修改的文件（保持不变）

| 文件 | 原因 |
|------|------|
| `CLIProfile.swift` | 模型层抽象合理，内置 preset 配置无需变更 |
| `CLIProfileManager.swift` / `ProfileStore` | 环境管理和持久化逻辑无需变更 |
| `PipelineModels.swift` | `effectiveCommand(profile:)` 的动态解析逻辑正是本次优化的核心依赖 |
| `ClaudeRunner` / `CodexRunner` / `CursorRunner` / `CommandRunner` | 运行时通过 `ProfileStore.current()` 读取当前环境，无需变更 |

## 影响范围

| 场景 | 变化 |
|------|------|
| 首次启动 | 检测 + 选择环境，更简洁 |
| Settings | 环境切换下拉 + 检测状态，取代 4 个命令编辑框 |
| 新建 Step | 只需选 Tool + 写 Prompt，命令自动生成 |
| Step 详情 | Tool/Model 选择器 + Resolved Command 预览（带复制），命令编辑收入 Advanced |
| AI 生成 Pipeline | 只保存 tool + model，不硬编码命令 |
| 切换环境 | 所有未自定义命令的 Step 自动跟随新环境，无需逐个修改 |
| 已自定义命令的 Step | 不受环境切换影响，保持用户设置 |

## 验证方法

1. 启动应用，进入 Settings，确认只显示环境切换和检测状态，不再显示命令编辑框
2. 切换 Default ↔ Internal，确认各工具显示的 executable 随之变化
3. 新建 Pipeline，添加 Step，确认 Step 详情页显示 Tool/Model 选择器和 Resolved Command 预览
4. 在 Step 详情页切换 Tool 和输入 Model，确认 Resolved Command 实时更新
5. 展开 Advanced 填入自定义命令，切换环境后确认该 Step 命令不受影响
6. 通过 AI 生成 Pipeline，确认各 Step 显示正确的 Tool badge 而非命令文本
7. 执行 Pipeline，确认命令能正确解析并运行
