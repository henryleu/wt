# 开发任务：实现 `wt sync` 命令

## 1. 概述
实现一个新的子命令 `wt sync`，用于**批量同步所有 worktree**。
目标：将所有 worktree（除主 worktree 外）当前分支的提交合并到 `main_branch`，然后将 `main_branch` 的最新状态应用到所有 worktree（包括主 worktree），使所有 worktree 处于完全相同的代码状态（指向同一个提交）。
若有任何冲突或异常，**立即中止**（不进行任何实际提交），并明确报告导致失败的具体 worktree 和分支，由用户手动解决。

## 2. 命令行为
- **命令名**：`wt sync`（无参数）
- **执行环境**：必须在 Git 仓库内，且 `.wt.toml` 配置有效。
- **前置条件**：
  - 所有 worktree（含主 worktree）必须**干净**（无未提交更改）。
  - 所有 worktree 均处于分支上（不得处于 detached HEAD），因为 `wt merge` 要求分支。
  - 主 worktree 必须处于 `main_branch` 上（`wt merge` 会确保，但 sync 应显式检查）。
  - 配置中的 `merge.remote` 必须有效（若 `merge.push = true`）。
  - 无其他 wt 操作在运行（通过锁保护）。

## 3. 详细步骤（原子性保证）
为保证**全或无**，先执行**预检查**（dry-run），确认所有分支均可无冲突合并到 `main_branch`，再执行实际合并和更新。

### 3.1 预检查阶段
1. **获取所有 worktree 列表**（使用 `worktree_roots`），过滤掉主 worktree。
2. 对每个 worktree：
   - 获取其**当前分支名**（`branch_of_worktree`）。若为 detached，报错终止。
   - 检查该分支是否**已合并**到 `main_branch`（`git branch --merged main_branch`）。若已合并，标记为“跳过合并”。
   - 若未合并，使用 **`git merge --no-commit --no-ff`**（或根据 `merge.strategy` 调整）在**主 worktree** 的副本（临时索引）中模拟合并，检测是否会产生冲突。
     - 重要：此模拟**不应修改任何实际分支或工作区**。可通过 `git merge --no-commit --no-ff` 但随后 `git merge --abort`（若成功，则 `git merge --abort` 丢弃合并状态；若冲突，则 abort 并记录）。
     - 更稳健的方法：使用 `git merge-tree` 或 `git merge-base` 判断，但为与 `wt merge` 策略一致，建议使用实际 `git merge` 模拟，然后立即 abort。
   - 若模拟成功（无冲突），记录该分支需合并。
   - 若模拟失败，**立即终止整个 sync**，报出冲突分支名，并提示用户手动解决。

3. 若所有分支均能通过预检查，则进入实际执行阶段。

### 3.2 实际执行阶段
1. **锁定项目**（`project_lock_acquire sync`），防止其他操作干扰。
2. **依次合并每个未合并的分支**（按任意顺序，但为减少冲突可能，可按分支名排序）。
   - 对每个分支，执行与 `wt merge` 完全相同的操作：
     - 切换到主 worktree（但主 worktree 已在 main_branch，无需切换）。
     - 执行 `git merge --no-ff`（或 `--ff-only`，根据策略），带上 `--log` 参数（配置 `merge.log`）。
     - 若合并成功，立即 `git push`（若 `merge.push = true` 且 remote 存在）。
     - 若合并失败（冲突），调用 `merge_failed` 函数处理（会 abort 并退出），但注意此时已有部分合并提交可能已存在，这违反了原子性。**因此，预检查已保证不会失败，此处的失败应视为异常**，若发生，仍按 `merge_failed` 处理并退出（但不会回滚前面的合并，这是设计取舍，可接受）。
3. **更新所有 worktree 到最新 main**：
   - 对**每个 worktree**（包括主 worktree）：
     - 切换到 `main_branch`（若已在 main_branch，则切换可能无影响，但确保分支存在）。
     - 执行 `git pull --ff-only`（或 `git fetch && git reset --hard origin/main_branch`，但后者会丢失本地未推送提交，但此时所有分支已合并，且 worktree 干净，故安全）。为了统一，使用 `git checkout main_branch && git pull --ff-only`（若本地 main 与远程同步，则无操作）。
   - 若更新失败（例如网络问题），报错并退出（但锁已释放）。
4. **释放锁**（通过 trap）。

### 3.3 输出信息
- 执行过程中，输出每个 worktree 的状态（跳过、合并、更新）。
- 若预检查通过，输出开始执行。
- 最后输出所有 worktree 已同步到 main 最新。

## 4. 错误处理与退出码
- 若预检查发现冲突，退出码 1，输出具体哪个 worktree/分支有冲突，并提示用户手动解决。
- 若执行阶段合并失败（不应发生），调用 `merge_failed`，输出冲突信息并退出。
- 若更新 worktree 失败，输出错误并退出。

## 5. 依赖与复用
- 复用现有函数：
  - `require_project`, `validate_config`, `worktree_roots`, `branch_of_worktree`, `is_clean`, `cfg_*` 等。
  - 复用 `cmd_merge` 中的**合并逻辑**，抽取出一个内部函数 `do_merge_branch(branch)`，供 `merge` 和 `sync` 共用。
  - 复用 `merge_failed` 和 `push_failed` 函数。
- 需新增内部函数：
  - `check_merge_conflict(branch)`：在主 worktree 中模拟合并，若无冲突返回 0，否则返回 1。
  - `sync_worktree_to_main(wt_root)`：将指定 worktree 切换到 main_branch 并更新。

## 6. 配置影响
- `merge.strategy`、`merge.remote`、`merge.push`、`merge.log` 均适用。
- 若 `merge.push = true`，每次合并后 push（与 merge 一致）。

## 7. 边界情况
- 若没有其他 worktree（只有主 worktree），`wt sync` 应仅更新主 worktree（即执行 `git pull`），输出提示。
- 若某个 worktree 当前分支就是 main_branch，跳过合并，但需要更新它到最新。
- 若某个 worktree 的分支已合并到 main_branch，跳过合并，但仍需更新该 worktree 到最新（因为它可能落后）。

## 8. 代码风格与约束
- 遵循现有脚本风格（set -euo pipefail，使用 `printf`，函数命名）。
- 所有输出使用 `info`、`warn`、`die` 等 helpers。
- 锁必须在 sync 开始时获取，结束前释放（即使失败）。
- 预检查阶段不应获取锁（只读操作），以允许其他操作同时进行？但为避免冲突，可以在预检查前获取锁，但考虑到预检查可能耗时，且多个 sync 同时运行的概率低，可以获取锁后进行预检查，但这样会阻塞其他操作。更安全：获取锁再检查，避免状态变化。采用：先获取锁，再进行预检查（但若预检查耗时，会阻塞其他命令）。这符合项目设计（所有写操作都锁）。所以 sync 从开始就获取锁。

## 9. 测试建议
- 测试场景：
  - 多个 worktree，分支均未合并，且无冲突 -> 成功。
  - 某个分支与 main 有冲突 -> 预检查失败，输出冲突分支。
  - 无其他 worktree -> 仅更新主 worktree。
  - 某个 worktree 已合并 -> 跳过合并，仅更新。
  - 主 worktree dirty -> 报错。
  - 非主 worktree dirty -> 报错。
  - 配置 `merge.push=true` 测试 push 是否执行。

## 10. 实现步骤（建议）
1. 在 `main()` 中添加 `sync` 命令分支。
2. 实现 `cmd_sync()` 函数：
   - 调用 `require_project` 和 `validate_config`。
   - 检查所有 worktree 是否干净，主 worktree 是否在 main_branch。
   - 获取需合并的分支列表。
   - 获取锁。
   - 执行预检查。
   - 若通过，执行实际合并和更新。
   - 释放锁。
3. 将 `cmd_merge` 中的合并逻辑提取为 `merge_branch_into_main(branch, main_wt, strategy, remote, push, log)`，返回 0/1。
4. 实现 `check_merge_conflict(branch)`。
5. 实现 `update_worktree_to_main(wt_root)`。

## 11. 文档更新
- 在 `cmd_help` 和 `usage` 中添加 `sync` 子命令说明。
- 更新 README（如有）描述 sync 功能。

---

**请根据以上规范实现 `wt sync` 命令，确保与现有代码风格一致，并尽量复用已有逻辑。**
