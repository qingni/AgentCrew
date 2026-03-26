# Step 上下文传递机制分析

## 当前实现

AgentCrew 的 pipeline 执行中，每个 step 独立运行，仅使用自己定义的 `prompt`。前一个 step 的 stdout 输出 **不会** 自动注入到下一个 step 的 prompt 中。

### 执行顺序控制

- **Sequential 模式**：step N 隐式依赖 step N-1，确保按顺序执行
- **Parallel 模式**：仅通过显式 `dependsOnStepIDs` 控制依赖
- 依赖关系只控制 **执行顺序**，不传递数据

### Step 输出用途

step 执行后的 `output` 仅用于：
- UI 展示（实时输出流）
- 运行历史记录

不参与后续 step 的 prompt 构建。

## 为什么当前设计是合理的

### 核心原因：Coding Agent 通过文件系统共享上下文

AgentCrew 编排的工具（Claude Code、Codex、Cursor）都是 Coding Agent，具备直接读写文件系统的能力。同一 pipeline 内的所有 step 共享同一个 `workingDirectory`，上下文传递天然发生在文件系统层面：

- Step 1（Claude）："在 src/ 下创建用户认证模块" → 写入文件
- Step 2（Codex）："为 src/ 下的认证模块编写单元测试" → 直接读取 Step 1 的产物

Step 2 不需要 Step 1 的 stdout，它需要的是 Step 1 写入磁盘的代码文件。

### 不做链式传递的理由

1. **Agent 的 stdout 包含大量过程日志**，不是有效的结构化信息，注入 prompt 会引入噪音
2. **浪费 token、增加成本**，Coding Agent 的输出动辄数千行
3. **可能超出 prompt 长度限制**
4. **Agent 自身已有上下文管理能力**，不需要外部注入

## 业内实践对比

| 工具/框架 | 上下文传递方式 | 适用场景 |
|-----------|---------------|---------|
| **GitHub Actions** | 同 job 内共享文件系统，跨 job 用 artifacts，仅少量元数据通过 outputs 传递 | CI/CD |
| **Makefiles / nx / just** | 通过文件产物关联任务，不传递 stdout | 构建系统 |
| **LangChain / LangGraph** | 前一步输出作为后一步输入（chain） | 纯 LLM 文本处理（摘要→翻译→格式化） |
| **AgentCrew（当前）** | 共享文件系统，不传递 stdout | Coding Agent 编排 |

LangChain 的链式传递是为 **纯文本处理** 设计的，与 Coding Agent 编排是不同的问题域。

## 未来扩展建议

| 阶段 | 方案 | 触发条件 |
|------|------|---------|
| 当前 | 维持现状，文件系统即上下文 | 工具全部为 Coding Agent |
| 中期 | 支持可选模板变量（如 `{{prev.output}}`），由用户主动引用前置 step 输出 | 引入分析型/决策型 step |
| 远期 | 完整链式传递 + 输出过滤 | 引入大量非 Agent 工具（curl、jq、数据库查询等） |

关键原则：**按需引入复杂度**，不为"看起来更完整"而提前过度设计。
