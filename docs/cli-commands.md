# CLI 非交互模式命令参考

> 以下命令均为非交互（headless）模式，适用于 Pipeline 自动化执行场景。
> `{{prompt}}` 为占位符，实际运行时会替换为 step 的 prompt 内容。

---

## Open Source 版本

### Cursor

```bash
cursor-agent --trust --model claude-4.6-opus-max-thinking -p {{prompt}}
```

查看可用模型：

```bash
cursor-agent models
```

### Codex

```bash
codex exec --sandbox workspace-write {{prompt}}
```

### Claude

```bash
claude --print --permission-mode bypassPermissions --add-dir . -p {{prompt}}
```

---

## Internal 版本

### Cursor（executable: `cursor-agent`）

```bash
cursor-agent --trust --model claude-4.6-opus-max-thinking -p {{prompt}}
```

查看可用模型：

```bash
cursor-agent models
```

### Codex（executable: `codex-internal`，仅国内模型）

```bash
codex-internal exec --sandbox workspace-write --skip-git-repo-check {{prompt}}
```

### Claude（executable: `claude-internal`，仅国内模型）

```bash
claude-internal --print --permission-mode bypassPermissions --add-dir . -p {{prompt}}
```

---

## 示例

```bash
# Open Source
cursor-agent --trust --model claude-4.6-opus-max-thinking -p "总结下当前项目"
codex exec --sandbox workspace-write "当前项目总结下"
claude --print --permission-mode bypassPermissions --add-dir . -p "当前项目总结下"

# Internal
cursor-agent --trust --model claude-4.6-opus-max-thinking -p "总结下当前项目"
codex-internal exec --sandbox workspace-write --skip-git-repo-check "当前项目总结下"
claude-internal --print --permission-mode bypassPermissions --add-dir . -p "当前项目总结下"
```
