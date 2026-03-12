# AgentCrew

`AgentCrew` 是一个面向 macOS 的本地 AI CLI 编排工具，用来把 `Codex`、`Claude`、`Cursor/agent` 组织成可视化 Pipeline，并按依赖关系自动执行。

它的核心目标不是替代某一个 AI 工具，而是提供一个统一的 orchestration layer，让你可以把多种 AI CLI 串成一条可复用的工作流，例如：

- `Codex` 负责实现功能
- `Cursor` 或 `Claude` 负责复审
- 失败后按阶段重试或继续后续步骤

## 核心能力

- 可视化 Pipeline 编辑：按 `Stage -> Step` 组织任务
- 多工具混合执行：支持 `Codex`、`Claude`、`Cursor`
- AI 自动生成 Pipeline：输入自然语言任务，自动拆解为结构化步骤
- DAG 调度执行：支持并行、串行、显式依赖
- 运行监控与历史记录：查看步骤状态、输出、失败阶段和重试记录
- 命令环境切换：支持 `Default (Open Source)` 与 `Internal` 两套 CLI 环境
- Step 级命令覆盖：默认自动生成命令，也可对单个步骤手动覆盖
- 交互式终端模式：直接从应用中打开并使用 AI CLI
- 执行流图：用 Flowchart 查看波次、依赖关系和运行状态

## 适合的使用场景

- 把“实现 -> 复审 -> 修复 -> 验证”固化成标准流程
- 在同一个项目里组合多个 AI CLI 的长链路协作
- 对复杂任务做分阶段拆解，并让独立步骤并行执行
- 为本地代码仓库建立可重复运行的 AI 自动化工作流

## 项目结构概览

当前项目是一个基于 `SwiftUI` 的原生 macOS 应用，主要由以下几层组成：

- `Models`
  - 定义 `Pipeline`、`PipelineStage`、`PipelineStep`
  - 抽象 CLI 环境配置、工具类型、Planner 数据模型
- `Views`
  - 提供 Pipeline 编辑、Step 配置、执行监控、Flowchart、CLI 环境设置等界面
- `ViewModels`
  - `AppViewModel` 负责 Pipeline 生命周期、执行状态、AI 规划入口、运行历史等核心状态管理
- `Services`
  - `DAGScheduler` 负责依赖解析与波次调度
  - `AIPlanner` 负责把自然语言任务转成 Pipeline
  - `CodexRunner` / `ClaudeRunner` / `CursorRunner` / `CommandRunner` 负责实际调用 CLI

## 执行模型

AgentCrew 使用的是“基于 DAG 的波次并行调度”模型，而不是简单的全串行或全并行：

1. 所有 Step 会先解析出完整依赖关系
2. 当前依赖已满足的 Step 会组成一个 wave
3. 同一 wave 内的 Step 并发执行
4. 当前 wave 完成后，再进入下一 wave

依赖来源有两种：

- 显式依赖：Step 手动选择 `Run After`
- 隐式依赖：当一个 Stage 设置为 `sequential` 时，同 Stage 的后一个 Step 会自动依赖前一个 Step

这让它非常适合代码实现、复审、修复、验证这类既有先后关系、又存在可并行空间的任务。

## 支持的 CLI 环境

项目内置两套环境配置：

- `Default (Open Source)`
  - `cursor`
  - `codex`
  - `claude`
- `Internal`
  - `agent`
  - `codex-internal`
  - `claude-internal`

应用首次启动时会自动扫描本机 CLI，并推荐合适的环境。后续也可以在 `Settings` 中切换。

## 快速开始

### 1. 环境要求

- macOS 14+
- Swift 5.9+
- 已安装并登录至少一种 AI CLI

建议提前确认以下命令中至少部分可用：

```bash
cursor --version
codex --version
claude --version
```

如果你使用内部环境，则对应命令为：

```bash
agent --version
codex-internal --version
claude-internal --version
```

### 2. 启动项目

这是一个 Swift Package，可直接使用 SwiftPM 启动：

```bash
swift run AgentCrew
```

如需先编译：

```bash
swift build
```

### 3. 首次使用

1. 启动应用
2. 选择 CLI Environment
3. 新建 Pipeline，或使用 `AI Pipeline Generator`
4. 为每个 Step 配置 `Tool`、`Prompt`、可选 `Model`
5. 点击 `Run Pipeline` 执行

## 典型工作流

一个常见示例是：

1. `Codex` 实现功能
2. `Cursor` 做代码复审
3. `Codex` 根据复审意见修复
4. `Claude` 做补充验证或总结

你也可以把无依赖的实现步骤放在同一个 `parallel` Stage 中，让多个任务同时执行。

## 配置说明

Step 层默认不需要手写完整命令，只需要配置：

- `Tool`
- `Model`（可选）
- `Prompt`

系统会根据当前 CLI 环境自动生成最终命令。

如果某一步需要特殊行为，也可以在 `Advanced` 中填写自定义命令覆盖。此时该 Step 不再跟随全局环境切换。

## 文档

- `docs/cli-commands.md`：CLI 非交互命令参考
- `docs/simplify-cli-command-settings.md`：CLI 命令配置体系简化说明
- `docs/fix-cli-command-not-found.md`：CLI 找不到命令时的排查文档
- `docs/step-context-passing-analysis.md`：Step 上下文传递相关分析

## 依赖

项目当前依赖：

- [`SwiftTerm`](https://github.com/migueldeicaza/SwiftTerm)

## 当前项目判断

从现有代码来看，AgentCrew 目前已经具备一个完整的最小可用闭环：

- 有本地可视化 Pipeline 编辑器
- 有 AI 自动拆解任务能力
- 有 DAG 调度和多 CLI 执行能力
- 有运行监控、历史记录、失败重试和 Flowchart 可视化

整体定位比较清晰：它更像一个“面向本地 AI CLI 的轻量工作流编排器”，而不是单一聊天工具或单一代理外壳。