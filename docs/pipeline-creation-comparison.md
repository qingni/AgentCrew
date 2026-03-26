# Pipeline 创建方式对比流程图

> 推荐使用支持 Mermaid 的工具渲染（如 Cursor 预览、Typora、GitHub、VS Code Mermaid 插件等）。

```mermaid
flowchart TB
    subgraph entry [" "]
        direction LR
        S(("开始"))
    end

    subgraph paths ["两种创建方式"]
        direction LR

        subgraph manual ["手工自定义"]
            direction TB
            M1["选择项目目录"]
            M2["创建空 Pipeline"]
            M3["添加 Stage<br/>选择 并行 / 串行"]
            M4["添加 Step"]
            M5["配置 Tool / Prompt<br/>Command / 依赖"]
            M1 --> M2 --> M3 --> M4 --> M5
        end

        subgraph ai ["AI 自动生成"]
            direction TB
            A1["选择项目目录"]
            A2["输入任务描述"]
            A3["AIPlanner 调用<br/>Agent CLI 生成计划"]
            A4["解析 JSON 输出"]
            A5["自动创建<br/>Pipeline / Stage / Step"]
            A1 --> A2 --> A3 --> A4 --> A5
        end
    end

    subgraph shared ["共享链路"]
        direction TB
        C1["统一数据模型<br/>Pipeline → Stage → Step"]
        C2["持久化保存<br/>pipelines.json"]
        C3["可在编辑器中继续调整"]
        C4["运行前解析为 DAG"]
        C5["DAGScheduler 调度执行"]
        C1 --> C2 --> C3 --> C4 --> C5
    end

    S --> M1
    S --> A1
    M5 --> C1
    A5 --> C1

    style entry fill:none,stroke:none
    style paths fill:none,stroke:none
    style manual fill:#EFF6FF,stroke:#3B82F6,stroke-width:2px,rx:12,ry:12
    style ai fill:#FAF5FF,stroke:#A855F7,stroke-width:2px,rx:12,ry:12
    style shared fill:#ECFDF5,stroke:#10B981,stroke-width:2px,rx:12,ry:12

    classDef blue fill:#DBEAFE,stroke:#3B82F6,color:#1E3A5F,rx:8,ry:8
    classDef purple fill:#EDE9FE,stroke:#A855F7,color:#3B0764,rx:8,ry:8
    classDef green fill:#D1FAE5,stroke:#10B981,color:#064E3B,rx:8,ry:8
    classDef start fill:#4F46E5,stroke:#4F46E5,color:#FFFFFF

    class M1,M2,M3,M4,M5 blue
    class A1,A2,A3,A4,A5 purple
    class C1,C2,C3,C4,C5 green
    class S start
```

## 讲解要点

- **蓝色区域（手工自定义）**：先建空壳，再逐层补 Stage 和 Step，最后配执行语义。
- **紫色区域（AI 自动生成）**：输入一句话任务描述，模型自动生成完整的 Pipeline 结构。
- **绿色区域（共享链路）**：无论哪种方式创建，最终都汇入同一套数据模型、同一个编辑器、同一个 DAG 调度器。
