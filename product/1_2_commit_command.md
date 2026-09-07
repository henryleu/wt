# 开发任务：实现 `wt commit` 命令

## 0. 已确认的决策（用户确认）

- **智能体执行全部操作**：`git add` / `git commit` 由编码智能体（pi 或 Claude Code）用自带工具完成，脚本不直接执行写操作。
- **staging 由智能体决定**：智能体会加载 git-commit skill（Conventional Commits），自行判断如何暂存（`git add` 的范围由智能体决定）。
- **默认不 push**：提交后不自动推送；仅在显式 `--push` 或配置 `commit.push = true` 时推送。
- **无消息且无智能体可用 → 报错并提示**：绝不静默创建提交。

## 1. 概述

实现一个新的子命令 `wt commit`，用于在终端中**快速完成一次 Git 提交**：借助编码智能体（pi 或 Claude Code）非交互式地分析当前改动，加载 git-commit skill 生成 Conventional Commit 消息，并由智能体自己执行暂存与提交。适用于 wt 管理的任意 worktree（主 worktree 或 agent worktree）。

## 2. 命令行为

- **命令名**：`wt commit [message] [flags]`
- **位置参数**：
  - `message`（可选）：显式提交消息。提供后跳过智能体，由脚本直接提交（确定性路径）。
- **选项**：
  - `--agent pi|claude`：选择智能体（默认取 `commit.agent` 配置；未配置则自动检测：pi 优先，其次 claude）。
  - `--model <model>`：覆盖模型（pi 支持 `provider/id`，如 `ce/deepseek-v3.2-671b`（pi 默认模型）；claude 用其模型名）。
  - `--push`：提交成功后推送（目标 remote 复用 `merge.remote`，默认 origin）。
  - `--staged`：仅用于**显式消息**路径——只提交已暂存内容（不执行 `git add -A`）。智能体路径的 staging 由智能体决定，该 flag 不适用。
  - `--dry-run`：仅生成并打印提交消息（或显式消息），**不执行任何 git 写操作**。
- **执行环境**：必须在 Git 仓库内（复用 `require_project` / `repo_root`，任意 worktree 均可）。

### 2.1 两条路径

| 场景 | 路径 | 谁执行 git 写操作 |
|---|---|---|
| 无消息参数 | 智能体路径：上下文 → 智能体（加载 git-commit skill）→ 自行 add + commit | 智能体（bash 工具） |
| 有消息参数 | 确定性路径：`git add -A`（或 `--staged`）→ `git commit -m "<msg>"` | 脚本本身 |

## 3. 详细步骤

### 3.1 参数解析与配置读取

1. 解析 `message` 与 flags（`--agent` / `--model` / `--push` / `--staged` / `--dry-run`）。
2. 读取 `.wt.toml` 的 `[commit]` 段（agent / model / push），CLI flags 覆盖配置。
3. 确定智能体：`--agent` > `commit.agent` > 自动检测（`command -v pi`，其次 `command -v claude`；均不可用则报错）。
4. 若工作区完全干净（`git status --porcelain` 为空），直接输出 "nothing to commit" 并退出 0（不调用智能体）。

### 3.2 智能体路径

#### 3.2.1 组装上下文（stdin 管道输入）

```
=== git status --short ===
<git status --short 输出>

=== git diff (unstaged, tracked) ===
<git diff 输出>

=== git diff --staged ===
<git diff --cached 输出>

=== untracked files ===
<git ls-files --others --exclude-standard 列出的文件；每个文件内容截断（>64KB 只列名）>
```

- 所有 diff/内容做大小截断（例如合计上限 200KB），防止上下文爆炸。

#### 3.2.2 提示词（要求智能体）

1. 加载并使用 **git-commit skill**（Conventional Commits 规范：`type(scope): subject`，subject 短于 72 字符、祈使句、现在时）。
2. 分析全部改动，**自行决定如何暂存**（`git add` 范围由智能体判断；可用 `git add -A` 或按文件分组）。
3. 执行 `git commit`，生成规范提交消息（需要时含 body / footer）。
4. **禁止**：push、`--force`、`--amend`、修改 git config、删除分支。
5. 完成后输出最终提交消息与 `git log -1 --stat` 摘要。

#### 3.2.3 智能体调用（非交互式）

- **pi**：
  ```
  printf '%s' "$CONTEXT" | timeout 300 pi -p --no-session --model "$MODEL" -a \
      --skill "$HOME/.agents/skills/git-commit" <提示词>
  ```
  - `-p`：print 模式，处理完退出。
  - `-a/--approve`：信任项目文件（加载 AGENTS.md 上下文）。
  - 工具权限：pi 无内置沙箱，内置工具（read/bash/edit/write）以用户权限直接执行，print 模式不弹确认（已实测验证）。
  - `--no-session`：一次性运行，不落盘会话。
  - `--model` 可选；缺省用 pi 默认模型。
- **claude**：
  ```
  printf '%s' "$CONTEXT" | timeout 300 claude -p --output-format text \
      --model "$MODEL" --dangerously-skip-permissions <提示词>
  ```
  - skill 由 claude 自动发现（`~/.claude/skills/git-commit`，已确认存在）。
  - `--dangerously-skip-permissions`：非交互模式下允许其执行 git 命令（`--permission-mode bypassPermissions` 等价）。
  - 需要已登录；未登录时 claude 报错，脚本需捕获并给出 `/login` 提示（当前环境尚未登录，已实测确认）。
- **超时与退出码**：所有智能体调用带 `timeout`（默认 300s）并检查退出码；智能体非零退出 → `wt commit` 失败退出，工作区保持原状，不做猜测性回滚。

#### 3.2.4 结果校验

1. 记录调用前 HEAD（`git rev-parse HEAD`），调用后重新读取。
2. HEAD 未变化 → 警告 "agent produced no commit"，退出 1 并提示手动处理。
3. `--push`（且 HEAD 变化）→ `git push` 到 `merge.remote`；失败复用 merge 的 push 失败处理风格。

### 3.3 显式消息路径（确定性）

1. `--dry-run` → 打印消息，退出（不写任何内容）。
2. 否则 `git add -A`（除非 `--staged`）→ `git commit -m "$message"`。
3. 提交失败（hook 等）→ 保持工作区原状，输出 git 错误，退出 1（不改动用户已有更改）。
4. `--push` → 同上推送。

### 3.4 输出

- 打印最终提交消息与 `git log -1 --oneline --stat`。
- `--dry-run`：打印智能体生成的提交消息（智能体不可用且无显式消息时，打印提示）。

## 4. 错误处理与退出码

| 场景 | 退出码 | 行为 |
|---|---|---|
| 非 Git 仓库 / 配置无效 | 1 | 复用 `require_project` |
| 工作区干净 | 0 | "nothing to commit" |
| 无消息且智能体不可用（未安装/未登录） | 1 | 提示：`wt commit "feat: ..."`，或安装/登录智能体（claude 提示 `/login`） |
| 智能体调用失败 / 超时 | 1 | 输出错误，工作区保持原状，提示手动检查 |
| HEAD 未变化 | 1 | 警告 "agent produced no commit" |
| 提交失败（hook 等） | 1 | 输出 git 错误，保持工作区原状 |
| push 失败 | 1 | 复用 merge 的 push 失败处理风格 |

## 5. 依赖与复用

- **复用现有函数**：`require_project`、`repo_root`、`require_cmd`、`info` / `warn` / `die`、`cfg_*`（yq 读配置）、`merge.remote` 配置及 merge 的 push 失败处理。
- **新增内部函数**：
  - `commit_prompt_context()`：组装 3.2.1 的 stdin 上下文（含截断）。
  - `detect_commit_agent()`：pi → claude 自动检测。
  - `commit_agent_pi(context, model)` / `commit_agent_claude(context, model)`：发起并校验智能体调用。
  - `commit_push()`：提交成功后推送（复用 remote 逻辑）。

## 6. 配置影响

`.wt.toml` 新增可选 `[commit]` 段：

```toml
[commit]
# 使用的编码智能体：pi | claude（缺省自动检测）
agent = "pi"
# 模型（pi: provider/id 如 ce/deepseek-v3.2-671b（pi 默认模型）；claude: 模型名）。空 = 智能体默认。
model = ""
# 是否在提交后自动推送（默认 false，安全优先）
push = false
```

- 说明：`wt commit` 不获取项目锁（提交是轻量操作；git 自身保证 index 原子性）。若要与 `wt merge`/`wt sync` 并发安全，可在计划阶段再评估是否需要锁——**默认不加锁**，保持简单。

## 7. 边界情况

- **无任何改动**：直接提示，不调用智能体。
- **无消息 + 智能体不可用**：报错 + 提示显式消息（已确认决策）。
- **智能体只读未提交**：HEAD 未变化 → 警告并提示手动提交。
- **消息为空/仅空白**（显式路径）：视为失败，提示。
- **大 diff / 大仓库**：上下文截断（3.2.1），防止超限。
- **未跟踪文件**：纳入上下文（列表 + 内容截断）。
- **在非主 worktree 执行**：正常（`repo_root` 定位仓库）。
- **智能体残留进程/会话锁**：超时后报错，提示手动检查（claude 有会话锁）。

## 8. 代码风格与约束

- 遵循现有脚本风格：`set -euo pipefail`、`printf`、函数命名、`info` / `warn` / `die` helpers。
- 所有智能体调用：带超时 + 退出码检查。
- 绝不自动 push（除非显式 `--push` 或配置开启）。
- 不修改 git config、不 `--force`、不删分支（写入提示词约束 + 脚本不做这类操作）。
- 保持 diff 最小化，只新增 commit 相关代码。

## 9. 测试建议

| 场景 | 预期 |
|---|---|
| 干净工作区 | "nothing to commit"，退出 0 |
| 修改 + 未跟踪文件，pi 可用 | 生成 Conventional 消息并提交；HEAD 前进；staging 由智能体决定 |
| claude 未登录 | 报错并提示 `/login`（或 pi 路径正常） |
| `wt commit "fix: typo"` | 直接 `git add -A` + 提交 |
| `wt commit "fix: typo" --staged` | 只提交已暂存内容 |
| `--dry-run` | HEAD、index 均不变 |
| `--push` 成功 / remote 不可用 | 推送成功 / 推送失败报错 |
| hook 失败 | 工作区保留、退出 1 |
| 智能体卡住（模拟超时） | 超时报错、退出 1 |
| 无消息且 pi/claude 均不可用（PATH 移除） | 报错 + 提示显式消息 |

## 10. 实现步骤（建议）

1. `main()` 增加 `commit` 分支；`usage` / `cmd_help` 增加说明。
2. 实现 `cmd_commit()`：参数解析（message、`--agent`、`--model`、`--push`、`--staged`、`--dry-run`）、配置读取、干净检查。
3. 实现 `commit_prompt_context()`（上下文组装 + 截断）。
4. 实现 `detect_commit_agent()` 与 `commit_agent_pi()` / `commit_agent_claude()`（超时 + 退出码校验）。
5. 实现显式消息路径（`git add -A` / `--staged` → `git commit -m`）。
6. 实现结果校验（HEAD 前后比较）+ 可选 `commit_push()`。
7. 更新 README / wt_manual.md。

## 11. 文档更新

- `cmd_help` 与 `usage`：增加 `commit` 子命令说明。
- `wt_manual.md`：新增 `wt commit` 章节（两种路径、flags、配置示例）。
- README（如有命令清单）：增加示例：
  ```
  wt commit                     # 智能体分析改动并提交
  wt commit "fix: typo"         # 显式消息直接提交
  ```

---

**请根据以上规范实现 `wt commit` 命令，确保与现有代码风格一致，并尽量复用已有逻辑。实现前请先在本地验证 pi / claude 的非交互式调用（当前环境：pi 已实测可用；claude 未登录，需先 `/login`）。**
