## cursor agent:(gpt-5.4-xhigh)

**输入语句**

agent --trust -p "总结下当 前项目"

agent --model opus-4.6 -p "总结下当 前项目"


**查看模型**

agent models

## codex agent: (gpt-5.4-codex-xhigh)

**输入语句**
codex-internal exec "当前项目总结下"


## claude agent:（只有国内模型，暂不用）

**输入语句**

claude-internal -p "当前项 目总结下"



有几个遗漏点需要优化：
1）按项目管理 Pipeline：
一个项目下支持创建多个 Pipeline。当前是按 Pipeline 维度操作，导致同一项目需要重复选择项目。建议调整为“先选择项目，再在项目下创建/管理多个 Pipeline”。

2）Pipeline 运行后锁定 Stage：
点击 Run Pipeline 后，当前 Pipeline 对应的每个 Stage 不可再编辑（建议至少在运行期间不可修改，避免执行过程配置被变更）。

3）补充运行历史与过程展示：
Run Pipeline 后，增加“运行历史”界面，便于查看每次执行记录；每个 Stage 需清晰展示执行时间、进度、状态等信息。当前底部输出区可读性较弱，建议参考示意图，以更直观的方式展示运行过程。


