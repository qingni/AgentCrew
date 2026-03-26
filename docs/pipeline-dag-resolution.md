# Pipeline 运行前 DAG 解析流程

> 推荐使用支持 Mermaid 的工具渲染（如 Cursor 预览、Typora、GitHub、VS Code Mermaid 插件等）。

## 整体流程

```mermaid
flowchart TB
    subgraph input ["编辑态数据"]
        direction TB
        P["Pipeline"]
        P --> S1["Stage A (parallel)"]
        P --> S2["Stage B (sequential)"]
        S1 --> ST1["Step 1"]
        S1 --> ST2["Step 2"]
        S1 --> ST3["Step 3"]
        S2 --> ST4["Step 4"]
        S2 --> ST5["Step 5"]
    end

    subgraph resolve ["第 1 步：依赖展平"]
        direction TB
        R1["遍历所有 Stage 和 Step"]
        R2["收集显式依赖<br/>dependsOnStepIDs"]
        R3["如果 Stage 是 sequential<br/>注入前一个 Step 为隐式依赖"]
        R4["输出一维 ResolvedStep 数组"]
        R1 --> R2 --> R3 --> R4
    end

    subgraph validate ["第 2 步：环路校验"]
        direction TB
        V1["统计每个 Step 的入度"]
        V2["Kahn 拓扑排序"]
        V3{"visited == total?"}
        V4["通过"]
        V5["抛出 cyclicDependency"]
        V1 --> V2 --> V3
        V3 -- 是 --> V4
        V3 -- 否 --> V5
    end

    subgraph schedule ["第 3 步：波次调度"]
        direction TB
        W1["筛选所有依赖已完成的 Step"]
        W2["过滤掉依赖失败的 Step<br/>标记为 skipped"]
        W3["组成当前 Wave"]
        W4["TaskGroup 并发执行<br/>Wave 内所有 Step"]
        W5["收集结果<br/>更新 finalizedStatuses"]
        W6{"还有未完成的 Step?"}
        W1 --> W2 --> W3 --> W4 --> W5 --> W6
        W6 -- 是 --> W1
        W6 -- 否 --> W7["执行结束"]
    end

    P --> R1
    R4 --> V1
    V4 --> W1

    style input fill:#EFF6FF,stroke:#3B82F6,stroke-width:2px,rx:12,ry:12
    style resolve fill:#ECFDF5,stroke:#10B981,stroke-width:2px,rx:12,ry:12
    style validate fill:#FFF7ED,stroke:#F59E0B,stroke-width:2px,rx:12,ry:12
    style schedule fill:#FAF5FF,stroke:#A855F7,stroke-width:2px,rx:12,ry:12

    classDef data fill:#DBEAFE,stroke:#3B82F6,color:#1E3A5F,rx:8,ry:8
    classDef step fill:#BFDBFE,stroke:#3B82F6,color:#1E3A5F,rx:8,ry:8
    classDef proc fill:#D1FAE5,stroke:#10B981,color:#064E3B,rx:8,ry:8
    classDef check fill:#FEF3C7,stroke:#F59E0B,stroke-width:1.5px,color:#92400E
    classDef wave fill:#EDE9FE,stroke:#A855F7,color:#3B0764,rx:8,ry:8
    classDef fail fill:#FEE2E2,stroke:#EF4444,color:#991B1B,rx:8,ry:8

    class P,S1,S2 data
    class ST1,ST2,ST3,ST4,ST5 step
    class R1,R2,R3,R4 proc
    class V1,V2,V4 proc
    class V3 check
    class V5 fail
    class W1,W2,W3,W4,W5,W7 wave
    class W6 check
```

## 波次调度示例

以上图中的 Pipeline 为例，假设 Step 4 显式依赖 Step 1：

```mermaid
flowchart LR
    subgraph wave1 ["Wave 1"]
        direction LR
        W1S1["Step 1"]
        W1S2["Step 2"]
        W1S3["Step 3"]
    end

    subgraph wave2 ["Wave 2"]
        direction LR
        W2S4["Step 4"]
    end

    subgraph wave3 ["Wave 3"]
        direction LR
        W3S5["Step 5"]
    end

    wave1 --> wave2 --> wave3

    W1S1 -. "显式依赖" .-> W2S4
    W2S4 -. "隐式依赖<br/>(sequential 注入)" .-> W3S5

    style wave1 fill:#DBEAFE,stroke:#3B82F6,stroke-width:2px,rx:12,ry:12
    style wave2 fill:#EDE9FE,stroke:#A855F7,stroke-width:2px,rx:12,ry:12
    style wave3 fill:#D1FAE5,stroke:#10B981,stroke-width:2px,rx:12,ry:12

    classDef blue fill:#EFF6FF,stroke:#3B82F6,color:#1E3A5F,rx:8,ry:8
    classDef purple fill:#FAF5FF,stroke:#A855F7,color:#3B0764,rx:8,ry:8
    classDef green fill:#ECFDF5,stroke:#10B981,color:#064E3B,rx:8,ry:8

    class W1S1,W1S2,W1S3 blue
    class W2S4 purple
    class W3S5 green
```

## 讲解要点

- **蓝色区域（编辑态数据）**：用户在编辑器中搭建的 Pipeline → Stage → Step 树状结构，是静态的编辑态数据。
- **绿色区域（依赖展平）**：遍历所有 Stage/Step，收集显式依赖 `dependsOnStepIDs`；如果 Stage 模式为 sequential，自动将前一个 Step 注入为隐式依赖。产物是一维的 `[ResolvedStep]` 数组。
- **黄色区域（环路校验）**：用 Kahn 拓扑排序验证依赖图无环，有环则直接报错 `cyclicDependency`，不会进入执行。
- **紫色区域（波次调度）**：每轮动态计算当前所有"依赖已完成"的 Step，组成一个 Wave 并发执行；依赖失败的 Step 会被标记为 skipped 并传播到下游。循环直到所有 Step 都有终态。

## 一句话总结

> 先把树状的 Stage/Step 展平为一维数组并注入隐式依赖 → 用 Kahn 算法验证无环 → 然后每轮动态计算 ready step 组成 wave 并发执行，直到所有 step 都有终态。
