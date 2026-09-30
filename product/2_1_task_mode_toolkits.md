# 产品升级 2.1：Task Workspace 模式工具集（Task-Mode Toolkit）

## 0. 已确认的决策（用户确认）

- **Toolkit only**：wt 不拥有任务生命周期（不提供 `wt task create/ship` 之类动词）。任务 worktree 的创建/销毁由外部编排器（agent fleet / orchestrator）或人工驱动；wt 只提供可组合的状态与原语子命令。`task register/clear` 是**状态操作**，不是生命周期动词。
- **CLI 子命令暴露**：通用逻辑以子命令形式暴露（不做可 source 的 shell lib）。契约：**数据走 stdout，说明性输出走 stderr**（新增 `note()`，与 `info()` 并列；`info()` 保持 stdout 不变以免破坏现有消费者）。
- **wt 拥有自己的状态目录**：worktree 内 `<root>/.wt/task.json`（任务身份 claim）；用户级全局 `~/.wt/`（端口注册表、归档快照、锁）。**不**依赖主 checkout 的路径稳定性（re-clone / 改名不影响）。项目仓库的 `.wt.toml` 仍只放**已提交的配置**，不放运行态。
- **任务分支命名**：`[task]` 配置段支持带类型前缀的模板 `${type}/${slug}`（`task/`、`feature/`、`bugfix/` 等）。
- **端口角色任意化（app-role 无固定集）**：wt **不预设**项目里有哪些 app（不是只有 web/gateway）。端口按**角色名**（app 名，如 `gateway`、`web`、`console`、`boss`、`oss-proxy`…）分配与登记，角色集合由各项目自行声明或按需即用，数量不限；claim 与注册表存 `role → port` 映射，而非固定列。
- **向后兼容**：slot 模式现有命令行为完全不变；新增能力全部是增量。

## 1. 概述

现代 coding-agent 驱动的开发流程存在两种 worktree 拓扑：

| 模式 | worktree | 分支 | 生命周期 | 现状 |
|---|---|---|---|---|
| **Slot 模式** | 固定数量、长期存在（`<project>-<slot>`） | `workspace/<slot>`（slot 可换分支） | 人/agent 反复复用，不随任务销毁 | wt 现有能力 |
| **Task 模式** | 每个任务一个、用后即删 | 每任务一个分支（`${type}/${slug}`） | create → work → integrate → remove，由编排器驱动 | **本升级新增** |

本次升级让 wt 原生感知两种模式，并把"任务 worktree 运行期"所需的通用原语收编为子命令：身份 claim（版本化 JSON）、按 app 角色的端口分配注册表（角色集不固定，任意数量）、按 cwd 精确停进程、限额归档快照、模式断言。任何项目的 setup/teardown 钩子脚本都可以组合这些原语，而不必各自手写 lsof/锁/注册表逻辑。

设计原则延续 design.md：git 为事实来源（模式检测只依赖路径 + claim 文件）、单脚本部署、bash-3.2 兼容、macOS 可用（无 flock，用 mkdir 锁）、现有依赖不新增（yq 已是硬依赖，JSON 读取走 yq，输出用手写转义）。

## 2. 目标与非目标

### 2.1 目标

1. 新增 `wt task` / `wt port` / `wt proc` / `wt archive` / `wt assert` 子命令组（契约见 §5）。
2. wt 拥有状态层：worktree 级 `.wt/task.json` + 全局 `~/.wt/`（可被 `WT_STATE_DIR` 覆盖以便测试）。
3. `.wt.toml` 新增 `[task]` 段（分支模板、类型集、端口范围、归档预算），含校验与 `wt init` 模板。
4. 现有命令对 task worktree 的行为明确化：`current`/`list` 展示模式、`sync` 跳过、`remove` 拒绝、`merge` 不变、`doctor` 增加状态目录检查。
5. 新增集成测试覆盖以上全部。

### 2.2 非目标（本轮明确不做）

- 任务生命周期命令（create/ship/rm）、`pre_remove` 钩子 —— 编排器负责。
- 多机共享状态（`~/.wt/` 是单用户目录）。
- 注册表 GC / 归档保留策略。
- Slot 模式的端口分配（slot 继续用自己的 env 文件）。
- 任何具体编排器的适配代码（wt 保持中性）。

## 3. 状态层

### 3.1 布局

```
<task worktree>/.wt/task.json            # 本 worktree 的身份 claim（运行态，需 gitignore）
<repo>/.wt.toml                          # 已提交配置（位置不变，新增 [task] 段）

~/.wt/                                   # 用户级全局（WT_STATE_DIR 可覆盖）
  ports/<project_key>.tsv                # slug <TAB> role <TAB> port <TAB> created_at（每个 (slug, role) 一行）
  ports/<project_key>.lock.d/            # mkdir 锁；mtime > 60s 视为陈旧可抢
  archive/<project_key>/<slug>/          # wt archive 快照目标
```

- slot worktree 与主 checkout **保持无状态**：永不为它们创建 `.wt/task.json`。
- `project_key`：从主 worktree 计算 —— 取 `merge.remote`（默认 origin）的 URL，归一化（小写；去 `^(ssh|https?|git)://`；去 `user@`；scp 风格 `host:path` → `host/path`；去尾部 `.git` 与 `/`；**保留 host 与端口**），再 `git hash-object --stdin` 取前 12 位 hex。git 已是硬依赖，不需要 shasum。无 remote 时回退为 `git rev-parse --git-common-dir` 路径的哈希（文档标注：re-clone 不稳定，降级可接受）。
- 锁复用 mkdir + 陈旧抢占模式；**不**复用现有 `project_lock_acquire`（那绑定 git-common-dir，注册表必须能在 worktree 删除/re-clone 后存活）。

### 3.2 `.wt/task.json` schema（v1）

```json
{
  "version": 1,
  "slug": "fix-login",
  "branch": "task/fix-login",
  "type": "task",
  "ports": { "gateway": 5201, "web": 5301, "console": 5401 },
  "created_at": "2026-09-30T09:00:00Z",
  "label": "orchestrator-a"
}
```

- `version` 必填；读取端拒绝 `version != 1`（exit 4），未来 schema 变更在此处迁移。
- `slug` / `branch` / `created_at` 必填；`type` / `label` 可选；`ports` 必为对象（可为空 `{}`——不占端口的任务合法）。
- **`ports` 是任意 `role → port` 映射**，键集不固定：角色名即项目里的 app 名（`gateway`、`web`、`console`、`boss`、`oss-proxy`…）。角色名规则 `^[a-z][a-z0-9_-]*$`（读写端都校验；写端拒绝非法/重复键）。KEY=VALUE 输出一律加 `port.` 前缀（`port.console=5401`），与顶层键天然无冲突，消费者用同一条 sed 规则解析。
- **原子写**：`mkdir -p <root>/.wt` → 写 `<root>/.wt/.task.json.tmp.$$` → `mv`（同 fs rename 原子）。读取端解析失败一律按 corrupt 处理（exit 4）；`register` 遇 corrupt claim **拒绝静默覆盖**（exit 1，提示用 `wt task clear` 恢复）。
- **gitignore 防御**：`register` 时执行 `git check-ignore -q .wt/task.json`，未忽略则 stderr 警告（否则 `wt commit` 的 `git add -A` 会把 claim 提交进去）。
- 读取走 `yq -p=json -o=json`；输出（KEY=VALUE / JSON）用手写 `json_escape` + printf，不依赖 jq。

## 4. 配置新增（`.wt.toml`）

```toml
[task]
branch_pattern = "${type}/${slug}"   # 必须含 ${slug}；含 ${type} ⟺ types 非空
types = ["task"]                     # 允许的 ${type} 取值；第一个为默认
port_range_default = "10000-11000"     # 未声明角色的兜底 range（可省略；省略则未声明角色不可 claim）

[task.port_ranges]                   # 角色(app 名) -> 闭区间；键集由项目自定，任意数量
gateway = "10000-10200"
web = "10201-10400"
console = "10401-10600"

archive_budget = 60                  # wt archive 默认时间预算（秒）
archive_max_bytes = 26214400         # 单文件大小上限（25 MiB）
```

- 新增 `cfg_task_*` 访问器（沿用 `cfg_*` 默认值模式，wt.sh:188-201）；`validate_config`（wt.sh:204-231）新增校验：`branch_pattern` 必含 `${slug}`；range 匹配 `^[0-9]{4,5}-[0-9]{4,5}$` 且 lo ≤ hi、落在 1024–65535；port_ranges 键与角色同规则（`^[a-z][a-z0-9_-]*$`，重复/非法名 `die`）；budget/max_bytes 为正整数。失败沿用 `configuration error:` 前缀 `die`。
- 角色即配即用：未列入 `port_ranges` 的角色 claim 时走 `port_range_default`；两者皆无 → exit 1 报"no range for role R"。
- `wt init` 模板（wt.sh:1478-1508）追加 `[task]` 注释块。

## 5. 新命令契约

全局退出码契约（写入 help 与 design.md）：`0` 成功 · `1` 操作失败（`die`）· `2` 用法错误 · **`3` 断言不匹配** · **`4` 预期状态缺失/损坏**。

### 5.1 `wt task register [--slug S] [--branch B] [--type T] [--port ROLE=PORT]... [--label L]`

- 默认：`--branch` = 当前分支；`--slug` = 分支去掉最长匹配的 `branch_pattern` 字面前缀后净化；`--type` = 从分支按模板解析出的类型（模板无 `${type}` 时省略）。
- `--port ROLE=PORT` 可重复，钉任意角色的显式端口（导入/接管模式），如 `--port gateway=5201 --port console=5401`；角色名按 §3.2 规则校验。
- 幂等语义：
  - 已有合法 claim 且未给 `--port` → 原样打印（stderr `note "claim exists"`）。
  - 已有合法 claim **且** 给了 `--port` → 按给出的角色更新 claim 的 `ports` 映射并 upsert 对应注册表行（未提及的角色保留原值）（导入模式）。
  - 无 claim → 新建：`--port` 齐全的角色直接落 claim；否则对**未钉端口**的角色经注册表分配（默认分配 `[task.port_ranges]` 里声明的全部角色；一个角色都没声明且未给 `--port` → `ports` 为空 `{}`）；原子写 claim + 写注册表行。
  - 存在 corrupt claim → exit 1，绝不静默覆盖。
- stdout（精确格式；端口行按角色名字典序，一律 `port.` 前缀）：

  ```
  slug=fix-login
  branch=task/fix-login
  type=task            # 模板无 ${type} 时省略此行
  port.gateway=5201
  port.web=5301
  port.console=5401
  created_at=2026-09-30T09:00:00Z
  ```

### 5.2 `wt task read [--json]`

- 打印 claim（KEY=VALUE 同上，端口行为 `port.<role>=<n>`；`--json` 输出 schema 对象，`ports` 为映射）。
- exit 4 当缺失 / 解析失败 / `version != 1`（stderr 说明原因与恢复方式）。

### 5.3 `wt task clear`

- `rm -f <root>/.wt/task.json`（best-effort `rmdir .wt`）；缺失也 exit 0。**不**动注册表（释放端口是显式操作）。

### 5.4 `wt task slug [--branch B]`

- 纯函数：打印净化后的 slug。输入为分支名，去掉最长匹配的 `[task].branch_pattern` 字面前缀，`tr -cs 'a-z0-9' '-'`，去首尾 `-`。例：pattern `bugfix/${slug}`，分支 `bugfix/Fix Login` → `fix-login`。

### 5.5 `wt task branch <slug> [--type T]`

- 纯函数：打印 `expand_pattern([task].branch_pattern, type, slug)`。校验 slug `^[a-z0-9][a-z0-9-]*$` 与 type ∈ `[task].types`（模板含 `${type}` 且未解析到 → 报错）。不创建任何东西。

### 5.6 `wt port claim --slug S [--role NAME]...` / `wt port release --slug S [--role NAME]...` / `wt port list [--slug S] [--json]`

- claim：对每个 `--role`（可重复，顺序保留）取其 range（`[task.port_ranges][role]`，缺则 `port_range_default`，再缺 → exit 1）内**最低空闲**端口——跳过注册表已有行（任何 slug/role）与 lsof TCP LISTEN 占用。**未给 `--role` 时默认 = `[task.port_ranges]` 声明的全部角色**（声明序）。按 (slug, role) 幂等：已有行直接返回现值；给已知 slug 追加新角色 → 扩展式 upsert（本 worktree 有 claim 时同步更新其 `ports` 映射）。注册表锁内原子完成；任一角色耗尽 exit 1（stderr 指明角色与 range）。stdout：每角色一行 `port.<role>=<n>`。
- release：awk 过滤行 + 同目录临时文件 + `mv`；不给 `--role` 释放该 slug 全部行，给了只释放指定角色（并同步收缩 claim 的 `ports` 映射，若有）；幂等；写失败仅 stderr 警告、恒 exit 0。
- list：长表 TSV `slug\trole\tport\tcreated_at`（每 (slug, role) 一行，任意角色集友好；`--slug S` 过滤）；`--json` 输出对象数组 `[{"slug":...,"role":...,"port":...,"created_at":...}]`。

### 5.7 `wt proc stop --cwd DIR [--json]`

- `/usr/sbin/lsof -n -d cwd -Fn`（`command -v lsof` 兜底），匹配 cwd 在 DIR 内（含子目录）的进程，排除 `$$`/`$PPID`；`kill -TERM` → 每 100ms 轮询 `kill -0` 至多 5s → 存活者 `kill -KILL`。
- stdout：被信号过的 PID 每行一个（无则空）；`--json`：`{"stopped":[123],"killed":[]}`。
- best-effort：恒 exit 0。**只按 cwd 匹配，绝不按进程名**（避免误杀同名进程）。

### 5.8 `wt archive --slug S --path P [--path P ...] [--budget SEC] [--max-bytes N]`

- 目标 `~/.wt/archive/<project_key>/<slug>/`，每个 `--path`（文件/目录，调用方自行解析 glob）按项目内相对路径拷贝；单文件超 `--max-bytes` 跳过；`$SECONDS` 超出 `--budget` 后剩余项跳过；任何单项失败不影响整体。
- flags 缺省取 `[task].archive_budget` / `.archive_max_bytes`。stdout 为空，stderr 逐项 note。恒 exit 0。

### 5.9 `wt assert --mode main|slot|task`

- 用 §6 规则分类当前 worktree；匹配 exit 0；不匹配 stderr 说明实际与期望模式，**exit 3**。调用方（项目钩子）自行决定 force 旁路策略，wt 保持纯粹。

### 5.10 `wt current` 扩展

- 现有 `key=value` 行全部保留（`slot=` 对每个链接 worktree 照旧输出，basename 启发式不变）。
- 追加：`mode=main|slot|task`；task 模式下再追加 `slug=` 与 `port.<role>=<n>`（来自 claim 的 `ports` 映射，每个角色一行）。
- 新增 `--json`：单个对象输出全部字段（含 `ports` 映射）。

## 6. 模式检测与现有命令交互

```
mode_of_path ROOT:
  ROOT == 主 worktree        → main
  ROOT/.wt/task.json 存在    → task
  其余链接 worktree          → slot
```

- 刻意**不做**路径模式匹配：claim 文件是 task 模式的唯一事实来源；basename 启发式与 `slot_of_path` 现行为一致。detached HEAD 不影响分类（纯路径/文件判定）。
- `cmd_list`（wt.sh:525）：WORKTREES 表增加 MODE 列。
- `cmd_sync`（wt.sh:1245-1257 收集循环）：在 detached/dirty `die` 检查**之前**插入"含 `.wt/task.json` → `info "skip (task worktree)"` 并 continue"——濒死/脏的 task worktree 不应阻塞 slot 同步。
- `cmd_remove`（wt.sh:~733）：目标含 `.wt/task.json` → `die "task worktree; remove it via its orchestrator"`（防御性；正常不会被命名到）。
- `cmd_merge`：task worktree 内继续可用（这是编排器"integrate"步骤的推荐原语），行为不变。
- `cmd_doctor`：新增检查 `WT_STATE_DIR` 可写 + 打印 project_key 与注册表路径。
- `main()` case（wt.sh:1521-1537）新增：`task` / `port` / `proc` / `archive` / `assert`；组内子分发沿用 `cmd_config` 的 get/set 模式。
- 新函数建议插入位置：锁段（~322）与 `merge_branch_now`（~364）之间新开 "Task / port / state" 段：`wt_state_dir`、`project_key`、`normalize_remote_url`、`registry_file`、`registry_lock_*`、`port_bound`、`find_free_port`、`task_claim_file/read/write`、`sanitize_slug`、`mode_of_path`、`cwd_pids`、`stop_procs_by_cwd`、`copy_one_capped`、`cfg_task_*`；`note()` 紧挨 `info()`（~39）。

## 7. 典型组合（项目钩子视角，示例）

setup 钩子（由任意编排器在新建 task worktree 内调用）：

```sh
wt assert --mode task || exit 3                 # 拒绝在主 checkout / slot 内运行
claim="$(wt task register)"                     # 幂等：已有 claim 则原样返回
slug="$(printf '%s\n' "$claim" | sed -n 's/^slug=//p')"
gw="$(printf '%s\n' "$claim" | sed -n 's/^port.gateway=//p')"
console="$(printf '%s\n' "$claim" | sed -n 's/^port.console=//p')"   # 任意角色，同一解析规则
# …项目自身的 env 生成 / 依赖安装（wt 不介入）…
# 运行期临时需要新 app 端口时，按角色即用即分配：
wt port claim --slug "$slug" --role oss-proxy   # → port.oss-proxy=5601
```

teardown 钩子：

```sh
wt proc stop --cwd "$PWD"                       # 只停本 worktree 的进程
wt port release --slug "$slug"
wt archive --slug "$slug" --path scratch --path logs   # best-effort，恒 0
wt task clear
```

## 8. 测试计划

- harness：`test_helpers.sh` 增加 `export WT_STATE_DIR="$(mktemp -d ...)"`（每个用例独立全局态，对现有套件无影响）；`run.sh` FILES 注册新套件。
- `test_task.sh`：register 建 claim + 注册表行（多角色 `port.*` 行齐全）；重复 register 幂等（输出逐字节相同）；导入模式 `--port role=n` 钉端口 + upsert（未提及角色保留）；空 `ports` claim 合法；slug 推导（含空格/大写/多段前缀）；`task branch` 展开 + 非法 type/slug 拒绝；非法/重复角色名拒绝；`read` exit 4（缺失 / corrupt / version≠1）；corrupt 时 register exit 1；clear 幂等；`.wt/` 未 ignore 时 stderr 警告。
- `test_port.sh`：两个项目 → 两个注册表文件（project_key 隔离）；角色集隔离（同 slug 不同角色各得各的）；未声明角色走 `port_range_default`；无 range 角色 exit 1；最低空闲选择；预置行（任意角色）跳过；真实监听（后台 `nc -l`，无 nc 则 skip）跳过；耗尽 exit 1（指明角色）；按 (slug, role) 幂等；追加新角色扩展 upsert 且同步 claim；release 全量/按角色幂等；长表 TSV 格式精确。
- `test_context.sh`：main/slot/task 三态检测；`wt assert` 0/3；`wt current` 新行 + `--json`（yq 解析校验）；`wt sync` 跳过脏 task worktree 而非 die；`wt list` MODE 列。
- `test_proc_archive.sh`：`proc stop` 杀 cwd 内 sleeper、排除自身 shell；archive 尊重 `--max-bytes`/`--budget`、缺路径不失败、落盘路径 `~/.wt/archive/<key>/<slug>/` 正确。

## 9. 实施阶段

| 阶段 | 内容 |
|---|---|
| A | 状态层：`WT_STATE_DIR`、`project_key`、claim 原子读写、`mode_of_path`、`note()` + `test_task.sh` 基础用例 |
| B | 端口子系统：注册表文件/锁、`port claim/release/list` + `test_port.sh` |
| C | `task register/read/clear/slug/branch`、`proc stop`、`archive`、`assert`、`current` 扩展 + `test_proc_archive.sh` |
| D | `[task]` 配置 + 校验 + `init` 模板；`sync` 跳过；`remove` 拒绝；`doctor` 检查；文档更新 |

### 文档更新（本仓库）

- `design.md`：新增 Task 模式章节（模型、状态层、命令契约、退出码）；修订 §2.2 非目标（明确 task 模式下哪些 v1 非目标被有边界地放宽）与 §38 未来方向。
- `README.md`：命令表 + `[task]` 配置参考 + 两模式简介。
- `wt_manual.md`：新命令参考 + "为编排器/钩子编写" 章节。
- `caveats.md`：project_key 随 remote URL 变化的恢复方式；`.wt/` 必须 gitignore；`~/.wt/` 无备份策略。

## 10. 风险与开放问题

1. **project_key 漂移**：换 remote URL 或 `merge.remote` 会换 key；恢复 = 手工 `mv` 注册表与归档目录（罕见；`wt doctor` 打印 key 保证可发现性）。
2. **分支命名权**：task 分支由编排器创建，wt 只记录；`wt task branch` 供未来编排器让 wt 命名分支时使用。是否在 `register` 时强制校验 `[task].branch_pattern` → 留到有真实编排器需求再定。
3. **`lsof` 依赖**：`proc stop` 与 `port claim` 依赖；`wt doctor` 列为检查项。
4. **并发**：claim 原子 `mv` 保证读端永不看到半写；注册表写被 mkdir 锁串行化。
5. **`~/.wt/` 无备份**：定位为 scratch 级状态；archive 本身 best-effort。
