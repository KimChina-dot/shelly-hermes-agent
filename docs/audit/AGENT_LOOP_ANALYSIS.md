# Shelly Hermes Agent 循环全链路分析(PHASE 0 审计 · Worktree B-2)

> 审计对象:`flutter/lib/**`(基线 commit `5c46be2`,PHASE 54)。本文沿**一次用户 send → 一轮模型 round → 工具调用 → 审批 → 观察者副作用 → checkpoint 落盘**的完整路径逐跳标注 `文件:行号`(相对 `flutter/`),并给出事件发射序列与预算检查点清单。

## 0. 全链路一图

```
用户 send (chat_page → ChatSessionController.send, chat_session.dart:257)
  ├─ busy 分支:PHASE 51/54 steering(interrupt-and-steer)        chat_session.dart:269-282
  └─ idle:写 UserEntry → _startTask                              chat_session.dart:284-308
_startTask → TaskCoordinator.start(taskId, messages, resumeFrom)   chat_session.dart:519-609
  TaskCoordinator._launch → runner.run = _TaskRunner.run           task_queue.dart:179-204
    _TaskRunner.run:装配 gateway/registry/compactor/observer       chat_session.dart:1186-1422
    AgentRuntime.run:_injectMemory → AgentCore.run → _offerMemory  agent_runtime.dart:31-51
      AgentCore.run(while round < limits.maxRounds)                agent_core.dart:128-375
        gateway.completeStreaming(_buildRequest → bodyDecorator)   openai_gateway.dart:291-303
        tool dispatch:HardenedToolExecutor → CompositeToolRegistry runtime/tool_registry.dart:36-43
        approval:ApprovalBroker.request → PendingApproval → UI     approval_broker.dart:72-82
      观察者:_SessionObserver.onEvent(每事件)                     chat_session.dart:1425-1465
  TaskCoordinator listener → 完成时 _persistConversation + _dequeueNext  chat_session.dart:565-601
```

## 1. 入口:send() 与 busy 分支(PHASE 51/54)

`ChatSessionController.send`(`lib/state/chat_session.dart:257-308`):

1. **空守卫**:`:262-265`——纯空白文本+无图+无附件直接 return。
2. **busy 分支(PHASE 51 steering-lite + PHASE 54 interrupt-and-steer)**:`:269-282`
   - busy 期间附件/空文本拒收(`:270`);
   - `steerMode=true`(默认,`:189`)且队列空 → **把消息入队 + `cancel()` 打断当前任务**,完成观察者随后出队重发(`:275-279`);
   - 队列非空或 steerMode=off → 排队等待(`:280-281`);
   - `_enqueueMessage` FIFO、cap `maxQueuedMessages=5`、丢最旧(`:312-318`)。
3. **idle 路径**:`:284-297` 追加 `UserEntry`(带 images/fileNames),`phase=working`,生成 `conversationId = 'conv-<ms>'`;随后 `_startTask(initialMessages: [AgentMessage(user …)])`(`:298-307`)。

`_startTask`(`:519-609`):生成 `taskId='task-<ms>'`(`:531`)、追加 streaming `AssistantEntry`(`:532`)、启动前台服务 `TaskService.start()`(`:534`)、写恢复记录 `saveActiveTask`(`:535-539`),然后构造 `TaskCoordinator`,agentFactory 返回 `_TaskRunner`(`:541-564`,各 Future 依赖均带 2s timeout 兜底:图片库 `:549-554`、记忆库 `:555-559`、崩溃库 `:560-563`),并注册状态监听器(`:565-601`,见 §8)。`coordinator.start(taskId, initialMessages, resumeFrom)`(`:603-607`)。

## 2. TaskCoordinator:任务生命周期

`lib/core/task_queue.dart`:

- `start`(`:81-88`):去重后直接 `_launch`(chat 路径不走 `enqueue`/并发队列;`maxConcurrent` 为 null)。
- `_launch`(`:179-204`):发布 `recovering`(有 resumeFrom)或 `starting` → 构造 runner → 若 runner 实现 `AgentEventReporter` 则桥接审批事件(本实现走 `_SessionObserver`,bridge 未用)→ 异步执行 `runner.run(messages, task, resumeFrom)`,成功 `_finish`/异常 `_fail`。
- `_RunningTask` 同时是 `CancellationSignal`(`:271-280`);`stop()`/`cancel()` 置位(`:212-219`),AgentCore 在轮间/工具间/队列间轮询(`agent_core.dart:264,282,360`)。
- `_EventBridge`(`:254-269`):把 `ApprovalWaiting`→`TaskState.waitingTool`、`ApprovalFinished`→`running` 转成任务态(供任务页显示)。

## 3. _TaskRunner.run:一轮任务的装配(PHASE 43-53 汇总点)

`lib/state/chat_session.dart:1186-1422`,顺序:

1. **图片落盘**(仅 fresh send;resume 的消息已是路径,`:1192-1193`)。
2. 读 `ModelConfig`/`activeProfile`/`MemorySettings`(`:1194-1196`)。
3. **工具注册表**(CompositeToolRegistry,`:1256-1279`,顺序即派发优先级):
   1. `WorkspaceToolRegistry`(read_file/exists/list_files/search_files/write_file/apply_patch,`lib/core/tools/registry.dart:76-83`);
   2. `ShellToolRegistry`(run_command,`lib/core/shell/shell_executor.dart:208-215`);
   3. `TerminalSearchTools`(fast_find/smart_grep,`lib/core/tools/terminal_tools.dart:33-44`);
   4. `MemorySearchToolRegistry`(search_memory,聚合会话摘要+checkpoint+崩溃日志+记忆事实,`lib/core/tools/memory_search_tool.dart:42-48`,注册于 `chat_session.dart:1266-1271`);
   5. `KnowledgeToolRegistry`(append_knowledge,`lib/core/hermes/knowledge_tool.dart:18-24`);
   6. `NotesToolRegistry`(plan/note,PHASE 46 仅记态,`lib/core/tools/notes_tool.dart:31-32`);
   7. `_dshTools`(DSH 插件工具,来自 `dshToolsProvider`);
   8. `?mcpRegistry`(MCP HTTP 服务器工具,5s 连接超时,`:1216-1221`;McpGuardLedger 指纹种子 `:1215`);
   9. `?bridgeRegistry`(桌面桥工具,3s 超时,`:1225-1238`)。
   - **派发语义**:按名字命中第一个声明者,**核心工具压过插件**(`lib/core/runtime/tool_registry.dart:36-43`,`CompositeToolRegistry.execute`)。
4. **网关**(`:1280-1301`):test override 优先,否则 `OpenAiCompatibleGateway`,携带 `temperature/topP/maxTokens`(`config.*`,PHASE 51)与 `tools: registry.openAiToolsJson()`,并叠 `bodyDecorator = recitationBodyDecorator(notesTools, webSearchBodyDecorator(...))`(`:1293-1299`)。配置不完整 → `DemoModelGateway`(`:1300-1301`)。
5. **辅助网关 + 三个摘要工厂**(aux 模型,`:1307-1353`):`contextCompactorFor`/`toolDigestSummarizerFor`/`memoryExtractorFor`(`:877-965`),统一经 `_summaryGateway` 选 aux 或主(`:858-872`)。
6. **记忆注入源**:`memoryStore.loadFacts()`(`:1358-1363`,best-effort)。
7. **AgentRuntime 装配**(`:1365-1402`):`AgentContext{ sessionId, workspace, model, tools: HardenedToolExecutor(超时+超长摘要,lib/core/runtime/hardened_tool_executor.dart:11-24,39-64), checkpoints: _StoreCheckpoints, contextCompactor, hermes: HermesMemory(knowledgeStore + ForgettingPolicy), limits: AgentLimits(maxRounds=profile.maxRounds, maxToolCalls=profile.maxToolCalls), approvalPolicy: ShellApprovalPolicy(_NotesStateApprovalPolicy(ToolPolicy.standard.toApprovalPolicy())) }`(`:1392-1398`——plan/note 免审批 `:1043-1053`,shell 命令按风险分级 `lib/core/shell/shell_executor.dart:280-300`);`approvals: _session.broker`,`observer: _SessionObserver`。
8. **系统提示词组装**(fresh send;resume 保持 checkpoint 原样,`:1415-1420`):

```
systemPromptWithMemory(                                  chat_session.dart:1010-1037
  persona: personaWithRecitation(                        :997-1001
    personaWithToolRules(profile.systemPrompt),          :985-988  ← 人设+「工具使用守则」
    notesTools.recitationBlock(),                        :1411(任务开始为空,逐轮经 decorator 刷新)
  ),
  memories: memoryStore.loadFacts(),                     ← 「长期记忆」块;core 全注入,
)                                                          recall 填满至 memoryPromptCap=20,
                                                           archival 不注入(:971,1014-1025)
```

9. `runtime.run(effectiveMessages, cancellation, resumeFrom)`(`:1421`)。

## 4. AgentRuntime:Hermes 前后钩子

`lib/core/runtime/agent_runtime.dart:31-51`:

- `_injectMemory`(`:56-80`):仅 fresh send、非空任务时,`hermes.recall(task)` 把知识账本相关经验作为**第二条 system 消息**前置(`:69-76`);resume 不重注(`:61`)。
- `core.run(...)` 后 `_offerMemory`(`:82-91`):`AgentCompleted` 时 `hermes.maybeRemember` 经验入账(best-effort)。

## 5. AgentCore 主循环(单轮完整时序)

`lib/core/agent_core.dart:128-375`:

0. **恢复首排**:resume 且 `pendingToolCalls` 非空时先排干——`running` 态说明进程可能死在执行中,**不盲目重跑**,回到 awaitingApproval 重问(`:263-279`);`awaitingExecution` 视为已批准直接执行(`:277`)。
1. **取消检查**(轮首,`:282-284`)。
2. **上下文压缩**(PHASE 41/47):`compactor.needsCompaction(messages)` → `compact` → 替换 messages → 存 checkpoint → 发 `ContextCompacted`(`:287-307`);压缩失败吞掉(`:303-306`)。
3. `round += 1` 语义:`modelRound = round + 1`,`emit(ModelStarted(modelRound))`(`:308-309`)。
4. **模型调用**:有 `StreamingModelGateway` 则流式,每个非空 delta `emit(ModelDelta)`(`:313-320`);异常时发 `ModelFinished(succeeded:false)` 并 rethrow(`:321-328`)。成功后发 `ModelFinished{round, duration, succeeded:true, inputTokens, outputTokens, cachedTokens}`(`:329-339`,cachedTokens 从 `CachedTokensReply.promptCachedTokens` 解包)。
5. **预算检查点 #1(token)**:`round += 1`(`:340`)、`consumedTokens += input+output`(`:341`),`consumedTokens > limits.maxTokens` → `AgentStopped('token_budget_exceeded')`(`:342-344`)。
6. 助手消息入列(`:346-352`);**无 toolCalls → 存 checkpoint 并 `AgentCompleted`**(`:353-357`)。
7. **工具循环**(`:359-372`),每个 call:
   - **预算检查点 #2(取消)**(`:360-362`)、**#3(工具次数)**:`toolCallCount += 1; > maxToolCalls → AgentStopped('tool_budget_exceeded')`(`:363-366`);
   - pending 队列置 `awaitingApproval` 并存 checkpoint(`:367-370`);
   - `executePending(call, approvedByResume: false)`(`:371`)。
8. 循环耗尽 → `AgentStopped('round_limit_exceeded')`(`:374`)。`AgentLimits` 默认 16 轮/64K tokens/32 工具(`lib/core/models.dart:167-177`),实际值来自 profile。

### executePending 内部(`:158-258`)

- **审批门**(非 resume 时):`DiffHunkApproval.expand(call)` 把 apply_patch 拆 hunk(`:162`);策略判定**失败即要求审批**(fail-closed,`:163-169`);逐 hunk `emit(ApprovalWaiting)` → `await _approvals.request(hunk)` → `emit(ApprovalFinished)`(`:174-199`);部分批准 → `collapse` 合并回一个 call(`:200-206`);全拒 → 清队列、存 checkpoint、以 tool 消息 `'Tool call rejected by user'` 回填模型(`:208-217`)。
- **执行态落盘**:先 `awaitingExecution` 存 checkpoint,再 `running` 存 checkpoint(`:220-227`)——两段式写入是进程死亡后"不盲目重跑"判定的依据。
- `emit(ToolStarted(id, name, argumentsJson))`(`:228`)→ `_tools.execute`(`:232`)→ `emit(ToolFinished{succeeded, result})`(`:233-247`,失败 rethrow → 任务 failed)。
- 收尾:清 pending、存 checkpoint、追加 `AgentMessage(role:tool, content, toolCallId)`、再存 checkpoint(`:250-257`)。

## 6. Gateway 请求构造与 bodyDecorator 链

`OpenAiCompatibleGateway._buildRequest`(`lib/core/gateway/openai_gateway.dart:291-303`):`{model, messages: encodeMessages(messages), stream, tools?, temperature?, top_p?, max_tokens?}` → `bodyDecorator?.call(body)` → `jsonEncode`。

**decorator 链(内→外)**:`webSearchBodyDecorator` 先跑,`recitationBodyDecorator` 后跑(外层最后写,见 `chat_session.dart:1293-1299` 构造与 `:1072-1073` 的 `inner(body)` 先调):

1. `webSearchBodyDecorator`(`lib/core/gateway/web_search.dart:12-42`):按 baseUrl 能力三态——`none` 不动;智谱类 `pluginTool` 往 `tools` 追加 `{'type':'web_search', ...}`;OpenRouter 类 `modelSuffix` 给 model 追加 `:online`。
2. `recitationBodyDecorator`(PHASE 53,**KV-cache 安全**):`lib/state/chat_session.dart:1067-1093`——先剥离上一轮 decorator 追加的 recitation 消息(按 `_recitationMarker` 前缀识别,`:1096`),再把 `notesTools.recitationBlock()`(`lib/core/tools/notes_tool.dart:118-134`,计划编号列表+最新进展)作为**最后一条 role=user 消息追加到 messages 末尾**(`:1084-1090`)。设计动机注释在 `:1055-1065`:改写第一条 system 消息会击穿 provider 前缀缓存;尾部追加保持前缀字节稳定。plan 为空则完全不追加(`:1090` 前判断)。

流式解码:`completeStreaming`(`openai_gateway.dart:213-289`)——SSE 逐块 `delta.content` → `onDelta`(→ ModelDelta 事件);`delta.tool_calls` 片段进 `ToolCallAccumulator`;`usage` 尾包更新 input/output/cachedTokens(`cachedTokensFromUsage` 兼容 `prompt_tokens_details.cached_tokens` 与 DeepSeek `prompt_cache_hit_tokens`,并 clamp 到 prompt_tokens,`:124-140`)。非流式路径带 429/5xx 有界重试(`:196-209,322-323`)。

## 7. 审批链路

1. `AgentCore` 调 `_approvals.request(hunkCall)` → `ApprovalBroker.request`(`lib/core/approval_broker.dart:72-82`):**会话级 always-allow 集合命中则直接 approve**(PHASE 48,`:68-76`),否则建 `PendingApproval`(内含 `Completer<ApprovalDecision>`)并回调 `launcher`。
2. `launcher = ChatSessionController._onApprovalRequested`(`lib/state/chat_session.dart:172,204-209`):`phase=waitingApproval`、入 `approvalQueueProvider`(FIFO,`:1587-1589`)、经 `_ApprovalRouter` 交给 UI handler(`:211-220`,早到请求缓存重放)。
3. UI:chat_page 监听 `approvalQueueProvider`,首个请求弹出 `showModalBottomSheet(ApprovalSheet)`(`lib/features/chat/chat_page.dart:552-562`);Sheet 渲染队首(`lib/features/approval/approval_sheet.dart:59-64`),「批准/拒绝」→ `resolveApproval`(`:45-52` → `chat_session.dart:223-230`,队列清空后 phase 回 working);「本次会话不再询问」→ `approveAlwaysAndResume`(`:238-241` → broker.approveAlways);「跨会话记住」走可选持久化钩子(`approval_sheet.dart:18-30,213-220`,chat 页未接线时隐藏)。
4. 决策 complete 后 AgentCore 的 `await` 返回,继续 `ApprovalFinished` → 执行。任务异常收场时 `_drainApprovals` 兜底拒绝所有挂起审批(`chat_session.dart:245-255`)。

## 8. 事件发射序列与观察者副作用

一轮"用户提问 → 模型调工具 → 模型最终作答"的完整事件流(发射点均在 `agent_core.dart`,消费在 `_SessionObserver`,`lib/state/chat_session.dart:1425-1465`):

```
(可选)ContextCompacted                     :296  → notifyContextCompacted → NoticeEntry 气泡(:815-826)
ModelStarted(round)                        :309  → (无副作用)
ModelDelta(text) ×N                        :318  → appendDelta 逐字进 streaming AssistantEntry(:690-700)
ModelFinished{succeeded, in, out, cached}  :329  → recordTokens(更新会话累计,驱动 _ContextMeter,:742-747)
                                                   succeeded 时:recordUsage(→ shelly.usage.stats,带 cachedTokens,:751-770)
                                                   + recordRoundMemory(→ aux/主模型抽取事实 → shelly.memory.facts,:776-795)
ApprovalWaiting(hunk)                      :175  → (observer 无副作用;任务态经 _EventBridge → waitingTool)
ApprovalFinished{decision}                 :180/186 → (同上 → running)
ToolStarted(id, name, args)                :228  → upsertToolEntry 建/更新 ToolEntry(插在 streaming 助手行之前,:702-740)
ToolFinished{duration, succeeded, result}  :233/241 → upsertToolEntry 补结果/耗时/状态
…(下一轮 ModelStarted …)
```

任务收尾(非事件,TaskCoordinator listener,`chat_session.dart:565-601`):

- `completed`/`stopped`:停前台服务、`clearActiveTask`、`_drainApprovals`、终结 streaming 行(`_finishAssistantEntry`,`:611-620`)、phase=idle、**`_persistConversation`**(`:668-688`:写 `shelly.conversations` 摘要,cap 100)、**`_dequeueNext`**(PHASE 51:FIFO 出队一条 steering 消息重走 send,`_dequeueing` 防重入,`:334-346`)。
- `failed`:同上但追加 `ErrorEntry(humanizeAgentError(...))`(`:584-597`)。

## 9. Checkpoint 落盘点汇总(单轮内)

`_StoreCheckpoints.save` → `SettingsStore.saveCheckpoint('shelly.checkpoint.<convId>')`(`chat_session.dart:1467-1478`;`settings_store.dart:404-405`)。AgentCore 一轮内的保存时机:

| 时机 | 位置(agent_core.dart) |
|---|---|
| resume 排队:running→awaitingApproval | :273 |
| 全部拒绝 | :210,215 |
| pending→awaitingExecution | :223 |
| pending→running | :227 |
| 执行完成(清 pending) | :251 |
| tool 消息追加后 | :257 |
| 压缩后 | :295 |
| 每个工具调用置 awaitingApproval 时 | :370 |
| 完成/停止(最终快照) | :355,343,365,374 |

## 10. 取消与恢复语义

- **取消**:UI `cancel()`(`chat_session.dart:423-426`)→ coordinator.stop → `_RunningTask.cancelled` → AgentCore 在轮首/每个工具前/恢复队列间检查(`:264,282,360`)→ `AgentStopped('cancelled', snapshot())`。
- **恢复**:`recoverInterruptedTask`(`chat_session.dart:361-377`)以 `TaskRecovery.scan`(record+checkpoint 双证据,`lib/core/task_recovery.dart:71-77`)的 checkpoint 调 `_startTask(resumeFrom: …)`;coordinator 发布 `recovering`(`task_queue.dart:184-186`);AgentCore 从 checkpoint 的 round/consumedTokens/toolCalls/pendingToolCalls 续跑(`:133-139`)。

## 11. 观察结论(供 v3 参考)

1. **事件与 UI 强耦合在 `_SessionObserver`**:ModelFinished 的三个副作用(token/usage/memory)都发生在 observer 回调内,失败被静默吞掉——v3 拆 Brain 时这里是天然的接缝(事件已是 sealed class,加消费者无需改内核)。
2. **审批策略三层叠加**:`ToolPolicy.standard`(registry.dart:27-38)→ `_NotesStateApprovalPolicy`(plan/note 放行)→ `ShellApprovalPolicy`(shell 按风险分级,fail-closed),再叠 broker 的 always-allow 集合;v3 引入新工具家族时必须明确落在这三层的哪一层。
3. **单工具串行**:每轮工具逐个 `await`,审批也是串行 Completer;v3 若并行派发要重设计 pendingToolCalls 的 checkpoint 语义(现 schema 假设队列内至多一个 pending)。
4. **recitation 尾部追加不可回退**:PHASE 53 的 KV-cache 纪律依赖"decorator 只动 messages 末尾"这一约定,v3 改请求组装时需保住该不变量(测试基线含 cache-discipline 用例)。
