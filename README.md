<div align="center">
  <img src="Sources/AgentCrew/Assets.xcassets/AppIcon.appiconset/agentcrew_256x256.png" alt="AgentCrew Logo" width="128" />
  <h1>AgentCrew</h1>
  <p><b>一个面向 macOS 的本地 AI CLI 编排工作台（Orchestration Workbench）</b></p>
  
  <p>将 <code>Codex</code>、<code>Claude</code>、<code>Cursor-Agent</code> 等多种 AI 工具无缝组织成可视化工作流，在同一个项目中完成<b>实现、审查、修复、验证与人工重试</b>的完整闭环。</p>

  <p>
    <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+"></a>
    <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9+"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="License"></a>
  </p>
</div>

---

## ✨ 核心亮点 (Key Features)

AgentCrew 并非要替代某一个具体的 AI 聊天工具，而是提供一个统一的 **Orchestration Layer**，让多种 AI CLI 能以更稳定、可复用、可观察的方式协作。

### 🔄 独创双引擎驱动：Pipeline 与 Agent 模式并存
同一任务可自由在两种模式间切换，兼顾**执行效率**与**智能闭环**：
- **⚡️ Pipeline 模式**：基于静态 DAG 工作流，执行路径极短。适合目标明确、步骤固定、追求速度与成本控制的标准化任务。
- **🧠 Agent 模式**：基于多轮动态执行（Plan -> Execute -> Evaluate -> Replan）。支持自动诊断失败原因、自动补齐修复步骤，并在高风险操作前（如删除、大规模重构）挂起等待**人工审批 (Human-in-the-loop)**。

### 🌊 DAG 波次调度与并发执行
摒弃死板的全串行执行。AgentCrew 自动解析任务步骤之间的显式依赖（Run After）与隐式依赖（Sequential Stage），将可并行的步骤打包成「Wave (波次)」，**最大化利用并发性能**，大幅缩短长链路任务的等待时间。

### 🪄 AI 自动生成工作流 (Auto-Planner)
只需输入一句话自然语言（如：“给项目新增 JWT 用户认证与单测”），系统会自动为你拆解出 `Implement -> Review -> Fix -> Verify` 的结构化步骤，并自动分配合适的底层 AI 工具。

### 🛠️ 多模型 & 多 CLI 混合编排
- 深度兼容 `Cursor/cursor-agent`、`Claude`、`Codex`。
- 支持混合编排：例如用 Cursor 编写代码，用 Claude 进行深度 Review，再用 Codex 运行验证脚本。
- **智能 Profile 切换**：自动检测本机环境中的开源版/内部特供版命令，无缝切换。

### 💻 极致的 macOS 原生体验
- 基于 SwiftUI 构建，运行轻量、流畅。
- 可视化 Flowchart、全链路执行监控、本地系统通知。
- 支持在 GUI 中直接唤起内置交互式终端（基于 `SwiftTerm`），随时介入 AI 的上下文。

---

## 🆚 运行模式对比

| 维度 | ⚡️ Pipeline 模式 | 🧠 Agent 模式 |
|------|-------------------|---------------|
| **适用场景** | 任务明确、步骤固定、追求速度与确定性 | 需求模糊、需要反复“实现-审查-修复”的探索任务 |
| **计划生成** | 一次性固定生成 | 每轮动态重规划 (Re-planning) |
| **失败处理** | 任务中止，需人工修改流程后重跑 | 自动诊断并动态生成补救 (Patch) 与验证任务 |
| **协作方式** | 显式依赖的串行/并行执行 | 多角色协作 (Coder/Reviewer/Fixer) + 评估驱动 |
| **人工介入** | 失败中止后排查 | 支持中途状态拦截 (ask_human) 审批高危操作 |
| **成本/速度** | 🚀 更快、Token 消耗更低 | 🛡 更稳健、成功率更高 (相对耗时) |

---

## 📊 执行流程图

### ⚡️ Pipeline 模式（单次固定计划）

```mermaid
flowchart TD
    A[用户输入目标] --> B[Planner一次性生成固定Pipeline]
    B --> C[执行Stage1: 实现功能]
    C --> D[执行Stage2: Review]
    D --> E[执行Stage3: Verify/Fix]
    E --> F{全部成功?}
    F -- 是 --> G[结束 Completed]
    F -- 否 --> H[结束 Failed/Skipped]
    H --> I[用户手动改Pipeline后重跑]
```

### 🧠 Agent 模式（多轮智能闭环）

```mermaid
flowchart TD
    A[用户输入目标] --> B[Round1 Planning]
    B --> C[Round1 执行: Coder/Reviewer]
    C --> D[Round1 评估 Evaluator]
    D --> E{决策}
    E -- continue --> F[Round2 Planning]
    E -- replan --> F
    E -- ask_human --> H[等待人工确认]
    H --> F
    E -- finish --> G[结束 Completed]
    E -- abort --> X[结束 Failed]
    F --> I[Round2 执行: Fixer/Verifier]
    I --> J[Round2 评估]
    J --> E
```

---

## 🎯 典型使用场景 (Use Cases)

1. **自动化工作台**：把团队常用的 “实现代码 -> 代码 Review -> 修复问题 -> 跑通验证” 固化为可复用的标准 Pipeline。
2. **长链路协作**：在同一个项目里，让 Claude 负责写文档，Cursor 负责写代码，自动化脚本负责构建，一步到位。
3. **安全闭环**：在高危任务（如数据库迁移）中使用 Agent 模式，强制设置 `waitingHuman` 节点，由人工审查生成的变更后再继续执行。
4. **局部重试**：当长达几十步的 Pipeline 在最后一步失败时，无需从头再来，支持**按 Stage 或单 Step 原地重跑**。

---

## 🚀 快速开始

### 1. 环境要求
- macOS 14.0+
- Swift 5.9+
- 已在终端中登录并配置好至少一种受支持的 AI CLI（如 Cursor, Claude, Codex）

你可以通过以下命令验证环境：
```bash
cursor-agent --version
claude --version
codex --version
```

### 2. 编译与运行
AgentCrew 是标准的 Swift Package 项目，你可以直接通过命令行启动，或使用 Xcode 打开。

**通过命令行：**
```bash
git clone https://github.com/YourUsername/AgentCrew.git
cd AgentCrew
swift run AgentCrew
```
*(或者使用 `swift build` 进行构建)*

**通过 Xcode：**
双击 `Package.swift` 打开项目，选择你的 Mac 作为运行目标，点击 `Run (Cmd + R)`。

### 3. 使用指南
1. 启动 App 后，前往 `Settings` 确认已正确检测到本机的 **CLI Profile**。
2. 点击侧边栏底部的 `+` 选择一个本地代码仓库。
3. 点击 **AI Pipeline Generator**，输入你的任务需求，或手动创建 Pipeline。
4. 在 Pipeline 编辑器中检查各个 Step 的 Tool 和 Prompt（命令会根据环境自动生成，也可在 Advanced 中手写覆盖）。
5. 在右上角选择 `Pipeline` 或 `Agent` 模式。
6. 点击 **Run** 开始见证奇迹！📈

---

## 🏗️ 项目架构

本项目采用 SwiftUI 编写，核心架构如下：
- `Services/DAGScheduler.swift`: 负责解析依赖关系与波次 (Wave) 并行调度。
- `Services/AIPlanner.swift`: 负责与大模型交互，将自然语言转化为结构化执行步骤。
- `Services/CLIProfileManager.swift`: 负责不同环境 CLI 命令参数的自适应装配。
- `ViewModels/AppViewModel.swift`: 全局状态管理、会话生命周期与模式回退分析。

### 📚 相关文档
- [Pipeline 与 Agent 深度对比](docs/compare-pipeline-agent-modes.md)
- [支持的 CLI 命令参考](docs/cli-commands.md)
- [CLI 找不到命令的排查指南](docs/fix-cli-command-not-found.md)

---

## 🤝 参与贡献
欢迎提交 Issue 和 Pull Request！AgentCrew 仍处于快速演进阶段。
如果你希望增加新的 AI CLI 支持，或者改进 DAG 调度引擎，请参考 `docs/` 目录下的设计文档。

## 📄 许可证 (License)
本项目采用 [MIT License](LICENSE) 开源，请自由地在个人或商业环境中使用。