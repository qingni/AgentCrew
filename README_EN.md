<div align="center">
  <img src="Sources/AgentCrew/Assets.xcassets/AppIcon.appiconset/icon-256.png" alt="AgentCrew Logo" width="128" />
  <h1>AgentCrew</h1>
  <p><b>A Universal CLI Orchestration Workbench for macOS</b></p>
  
  <p>Not only seamlessly orchestrate multiple AI tools like <code>Codex</code>, <code>Claude</code>, and <code>Cursor-Agent</code> into visual workflows, but also <b>mix and match ANY traditional CLI commands (e.g., git, npm, docker, ffmpeg)</b>, creating a complete closed-loop for <b>development, testing, deployment, and automated operations</b> locally.</p>

  <p>
    <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+"></a>
    <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9+"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=for-the-badge" alt="License"></a>
  </p>

  <p>
    <b>English</b> | <a href="README.md">简体中文</a>
  </p>
</div>

---

## ✨ Key Features

AgentCrew is not meant to replace any specific AI chat tool, but rather to provide a unified **Orchestration Layer**, allowing multiple AI CLIs to collaborate in a more stable, reusable, and observable manner.

### 💻 Ultimate Native macOS Experience
- Built with SwiftUI for a lightweight and fluid experience.
- Visual Flowcharts, full-chain execution monitoring, and local system notifications.

<img src="./Images/auto-planner.png" alt="AgentCrew Running State" width="800" />

### 🔄 Dual Engine Architecture: Pipeline & Agent Modes
Switch freely between two modes for the same task, balancing **execution efficiency** and **intelligent closed-loops**:
- **⚡️ Pipeline Mode**: Based on static DAG workflows with the shortest execution path. Ideal for standardized tasks with clear goals, fixed steps, and a need for speed and cost control.
- **🧠 Agent Mode**: Based on multi-round dynamic execution (Plan -> Execute -> Evaluate -> Replan). Supports automatic failure diagnosis, dynamic patch step generation, and suspends for **Human-in-the-loop** approval before high-risk operations (e.g., massive refactoring, file deletion).

### 🌊 DAG Wave Scheduling & Concurrency
Say goodbye to rigid, purely sequential execution. AgentCrew automatically parses explicit dependencies (Run After) and implicit dependencies (Sequential Stage) between task steps, packing parallelizable steps into "Waves", **maximizing concurrency** and significantly reducing wait times for long-chain tasks.

### 🪄 AI Auto-Planner
Simply input a natural language requirement (e.g., "Add JWT user authentication and unit tests to the project"), and the system will automatically break it down into a structured `Implement -> Review -> Fix -> Verify` workflow, assigning the appropriate underlying AI tools.

### 🛠️ Multi-Model & Multi-CLI Hybrid Orchestration
- **Deep AI Tool Compatibility**: Natively supports LLM CLIs like `Cursor/cursor-agent`, `Claude`, and `Codex`.
- **Minimal CLI Environment Setup**: Provides a one-click toggle between standard and internal command mappings. This currently mainly affects `Codex` and `Claude`, while `Cursor` stays on a fixed command mode, with built-in environment probing for path resolution.

### 🔌 Universal Orchestration: Native Support for ANY Traditional CLI
Breaking the "AI tools only" limitation, AgentCrew's underlying architecture features a powerful universal executor:
- **Seamless Integration**: Perfectly supports `git`, `npm`, `python`, `docker`, `ffmpeg`, or any command runnable in the macOS terminal.
- **Interoperability with LLMs**: Safely passes the current step prompt to shell scripts via placeholders (`{{prompt}}`) or standard input (stdin), while still allowing prompts to reference dependency-step context when needed.
- **Structured Context Injection**: Instead of blindly piping raw stdout from one step to the next, AgentCrew injects structured execution memory and shared state on demand for better readability, cost control, and safety.
- **Infinite Hybrid Orchestration**: For example, use Cursor to write code, run `npm run test` to verify, and if it fails, trigger the Agent to capture the error, ask Claude to analyze and generate a patch, and finally use a custom shell script to deploy.

### 📊 Mode Insights & Recommendation
- **Intelligent Mode Recommendation**: Before creating a task, scores it based on complexity, risk level, and multi-tool collaboration needs, automatically recommending the most suitable mode (Agent or Pipeline), and providing dynamic switching suggestions during execution.
- **Mode Insights Dashboard**: Built-in analytics dashboard visualizing recommendation adoption rates, mode distribution, and 7-day trends. Supports exporting detailed logs for team retrospectives and engine tuning.

<img src="./Images/mode-insights.png" alt="Mode Insights Dashboard" width="800" />

---

## 🧠 Structured Memory & Shared State

AgentCrew does not mechanically dump the full stdout of one step into the next. Instead, it distills execution results into **structured context** and injects only the parts that are actually useful for downstream prompts.

### Two Layers
- **RunContext**: Handles **within-run dependency-chain passing**. Downstream steps can read fields such as `summary`, `decisions`, `artifacts`, `output.tail`, and `error.tail` from upstream dependency steps.
- **SharedState**: Handles **reusable state across steps, stages, and rounds**. Within the same `rootSessionID`, still-valid `decision`, `fact`, `artifactRef`, `issue`, and `resource` entries can be reused by later execution rounds.

### Why It Matters
- **Cleaner prompts**: By default, prompts receive summaries, decisions, and key artifacts rather than noisy process logs.
- **Clearer boundaries**: `{{step:...}}` only reads from dependency-chain steps, so context does not spread without control.
- **More stable multi-round execution**: In Agent mode, shared state can survive across rounds in the same root session, so the system does not need to re-understand everything from scratch.
- **Better debugging**: Runtime context is mirrored to `.agentcrew/context.md`, while shared state is persisted to `.agentcrew/runs/<rootSessionID>/shared-state.json` and mirrored to `shared-state.md`.

### How To Use It
- Reference structured context inside prompts: `{{step:Design.summary}}`, `{{step:Review.output.tail:500}}`
- Read pipeline-level runtime state: `{{pipeline.failed_steps}}`, `{{pipeline.last_failed.summary}}`
- When a step needs to publish reusable state explicitly, write `step-outbox` JSON and let the scheduler merge it after the wave finishes

For the full design walkthrough, see `docs/shared-state-overview.md`.

---

## 🎯 Typical Use Cases

Breaking the "AI tools only" boundary, AgentCrew is also an enhanced, localized `Jenkins` or visual `Make` that supports dynamic LLM planning and state management.

### 🤖 AI Development Closed-Loop
1. **Automated Workbench**: Solidify your team's common "Implement -> Review -> Fix -> Verify" process into a reusable standard Pipeline.
2. **Long-Chain Collaboration**: Within the same project, have Claude write documentation, Cursor write code, and automated scripts handle building—all in one go.
3. **Local Retry**: When a 30-step pipeline fails at the very end, there's no need to start over. Support for **in-place retries by Stage or single Step**.

### ⚡️ Universal Tasks & Orchestration
4. **Lightweight Local CI/CD (DevOps)**: Use Waves to concurrently execute `lint` and `test`. Upon success, sequentially execute `build`, call AI to generate a `CHANGELOG`, and suspend for manual (`waitingHuman`) approval before pushing to the cloud.
5. **Multimedia/Data Batch Processing**: Utilize DAG's maximum concurrency to launch dozens of processes (like `ffmpeg`) for time-consuming tasks, or concurrently scrape data before handing it over to LLMs for cleaning, analysis, and automated weekly report emailing.
6. **Intelligent Ops & Self-Healing**: Concurrently inspect local or remote services. When a metric anomaly causes a Step to fail, trigger the Agent mechanism to automatically pass the error to AI for a diagnostic report and repair command (Patch Step), executing recovery upon manual approval.

---

## 🆚 Execution Modes Comparison

| Dimension | ⚡️ Pipeline Mode | 🧠 Agent Mode |
|-----------|-------------------|---------------|
| **Best For** | Clear tasks, fixed steps, need for speed & certainty | Vague requirements, exploratory tasks needing "implement-review-fix" cycles |
| **Plan Gen** | One-time fixed generation | Dynamic re-planning per round |
| **Failure Handling** | Task aborts, requires manual fix and retry | Auto-diagnoses and dynamically generates Patch and verification tasks |
| **Collaboration** | Explicit dependency serial/parallel execution | Multi-role collaboration (Coder/Reviewer/Fixer) + Eval-driven |
| **Human Intervention**| Investigate after abort | Supports mid-flight interception (`ask_human`) for high-risk ops |
| **Cost/Speed** | 🚀 Faster, lower Token consumption | 🛡 More robust, higher success rate (relatively slower) |

---

## 🚀 Quick Start

### 1. Requirements
- macOS 14.0+
- Swift 5.9+
- At least one supported AI CLI logged in and configured in your terminal (e.g., Cursor, Claude, Codex).

Verify your environment with:
```bash
cursor-agent --version
claude --version
codex --version
```

### 2. Build & Run
AgentCrew is a standard Swift Package project.

**Via Command Line:**
```bash
git clone https://github.com/YourUsername/AgentCrew.git
cd AgentCrew
swift run AgentCrew
```

**Via Xcode:**
Double-click `Package.swift` to open the project, select your Mac as the run destination, and click `Run (Cmd + R)`.

### 3. Usage Guide
1. Launch the app and go to `Settings` to ensure your local **CLI Environment** is correctly detected, then switch between standard and internal command modes as needed (mainly for `Codex` and `Claude`).
2. Click the `+` at the bottom of the sidebar to select a local code repository.
3. Click **AI Pipeline Generator**, enter your task requirement, or manually create a Pipeline.
4. Review the Tool and Prompt for each Step in the Pipeline Editor (commands are auto-generated but can be overridden in Advanced settings).
5. Select `Pipeline` or `Agent` mode in the top right corner.
6. Click **Run** and watch the magic happen! 📈

---

## 🏗️ Architecture

This project is built with SwiftUI and organized into clear orchestration layers:

```mermaid
flowchart TB
    classDef layer_ui fill:#e3f2fd,stroke:#1976d2,stroke-width:2px,color:#0d47a1,rx:5px,ry:5px
    classDef layer_vm fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px,color:#4a148c,rx:5px,ry:5px
    classDef layer_core fill:#e8f5e9,stroke:#388e3c,stroke-width:2px,color:#1b5e20,rx:5px,ry:5px
    classDef layer_runner fill:#fff8e1,stroke:#ffa000,stroke-width:2px,color:#ff6f00,rx:5px,ry:5px
    classDef layer_runner_base fill:#ffecb3,stroke:#f57f17,stroke-width:2px,color:#bf360c,rx:5px,ry:5px
    classDef layer_data fill:#e0f7fa,stroke:#0097a7,stroke-width:2px,color:#006064,rx:5px,ry:5px

    subgraph UI ["UI Layer (SwiftUI)"]
        direction LR
        ContentView["Main View"]:::layer_ui
        PipelineEditor["Pipeline Editor"]:::layer_ui
        Flowchart["Visual DAG Graph"]:::layer_ui
        Monitor["Execution Monitor"]:::layer_ui
    end

    subgraph VM ["ViewModel Layer"]
        AppViewModel["AppViewModel<br/>Global state & lifecycle"]:::layer_vm
    end

    subgraph Core ["Core Orchestration"]
        DAGScheduler["DAGScheduler<br/>Dependency resolution & waves"]:::layer_core
        AIPlanner["AIPlanner<br/>Natural language to pipeline"]:::layer_core
        CLIProfileManager["CLIProfileManager<br/>CLI environment detection"]:::layer_core
    end

    subgraph Runners ["Execution Layer"]
        CLIRunner["CLIRunner<br/>Low-level process runner"]:::layer_runner_base
        CommandRunner["CommandRunner<br/>Custom command execution"]:::layer_runner
        ToolRunner["ToolRunner<br/>Built-in tool routing"]:::layer_runner

        Cursor["CursorRunner"]:::layer_runner
        Claude["ClaudeRunner"]:::layer_runner
        Codex["CodexRunner"]:::layer_runner

        ToolRunner --> Cursor
        ToolRunner --> Claude
        ToolRunner --> Codex

        CommandRunner --> CLIRunner
        Cursor --> CLIRunner
        Claude --> CLIRunner
        Codex --> CLIRunner
    end

    subgraph Models ["Data Models"]
        Data["PipelineModels / AgentModels / CLIProfile"]:::layer_data
    end

    UI -- "User Action" --> VM
    VM -. "State Binding" .-> UI

    VM -- "Plan / Execute" --> Core
    Core -- "Dispatch" --> Runners

    Runners -- "Progress / Result" --> VM

    UI -.-> Data
    VM -.-> Data
    Core -.-> Data
    Runners -.-> Data

    style UI fill:#f8f9fa,stroke:#c5cae9,stroke-width:2px,rx:10px,ry:10px,stroke-dasharray: 5 5,color:#333333
    style VM fill:#f8f9fa,stroke:#c5cae9,stroke-width:2px,rx:10px,ry:10px,stroke-dasharray: 5 5,color:#333333
    style Core fill:#f8f9fa,stroke:#c5cae9,stroke-width:2px,rx:10px,ry:10px,stroke-dasharray: 5 5,color:#333333
    style Runners fill:#f8f9fa,stroke:#c5cae9,stroke-width:2px,rx:10px,ry:10px,stroke-dasharray: 5 5,color:#333333
    style Models fill:#f8f9fa,stroke:#c5cae9,stroke-width:2px,rx:10px,ry:10px,stroke-dasharray: 5 5,color:#333333
```

Core modules:
- `Services/DAGScheduler.swift`: Resolves dependencies and schedules wave-based parallel execution.
- `Services/AIPlanner.swift`: Talks to LLM CLIs and turns natural language tasks into structured pipelines.
- `Services/CLIProfileManager.swift`: Adapts command generation to the active CLI environment.
- `Services/RunContextStore.swift`: Resolves `{{step:...}}` references within dependency scope, extracts summaries / decisions / artifacts, and mirrors runtime context to `.agentcrew/context.md`.
- `Services/SharedStateStore.swift`: Freezes wave snapshots, injects shared-state briefs, merges `step-outbox`, and persists structured state across rounds within the same `rootSessionID`.
- `ViewModels/AppViewModel.swift`: Manages global state, session lifecycle, retries, and mode fallbacks.

### 🔌 Universal Orchestration Internals

1. **Dynamic Routing**
   Inside `DAGScheduler`, any step with a custom command bypasses the built-in AI runners and goes straight to `CommandRunner`.
2. **Real Zsh Subprocesses**
   `CommandRunner` executes commands via `zsh -lc`, preserving shell startup behavior and using `command -v` to resolve real executable paths before launch.
3. **Prompt Delivery**
   If a command contains `{{prompt}}`, the prompt is safely shell-quoted and inlined. Otherwise, only the current step prompt is sent through stdin.

---

## 🤝 Contributing
Issues and Pull Requests are welcome! AgentCrew is still evolving rapidly.
If you'd like to add support for new AI CLIs or improve the DAG scheduling engine, feel free to dive into the code or open an issue to discuss it.

## 📄 License
This project is licensed under the [Apache License 2.0](LICENSE).
