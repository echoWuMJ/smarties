# 配对训练重启 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 中途 CFD 与完整 CPU learner 状态成套保存，用一个 resume 命令恢复。

**Architecture:** 非 MPI 管理程序协调三个独立 MPI 作业。在 proxy 收到 learner 已选动作但尚未交给 CFD 的边界暂停，保存该待执行动作，恢复时只发一次。learner 收齐 proxy 暂停确认后，在完整更新之间保存；全套文件经同步后原子发布。

**Tech Stack:** Python 3.12 标准库、C++14、MPI、Smarties native CPU、IBAMR/SAMRAI restart。

**Spec:** `docs/superpowers/specs/2026-09-18-paired-training-restart-design.zh-CN.md`

实施记录：四项任务及各自代码复核已完成。实际测试范围、计数与未覆盖限制见
`docs/reports/2026-09-18-paired-restart-validation.zh-CN.md`，不以勾选项代替测试证据。

## Global Constraints

- 一个 learner、两个 proxy、两个独立的 16-rank CFD 作业，learner 8 线程，原生 CPU 网络。
- 不接入 PyTorch，不重构 MPI 所有权，不增加 hash、冻结 contract 或新 baseline。
- 默认每 30 分钟墙钟时间请求一次保存，全局保留最近两套完整快照。
- 保存周期从上一套成功发布后重新计时；未完成的请求合并，不排队堆积。
- 物理推进慢不作为失败或超时依据。
- 不虚构终态清空活动轨迹；不同环境时间可以不同。
- 保留现有 regrid 修改；继续现有 feature/ibamr-eel2d-coupling 分支，不创建额外分支。
- 尚未通过真实恢复验收的功能不可写成 verified 经验，不可宣布可用于生产续算。

## 文件责任

`checkpoint_store.py` 只负责文件事务、空间与保留；`paired_run.py` 和新 shell 入口负责配置与命令；manager 负责协调；case/mailbox 负责 CFD 安全点；Smarties 状态所有者负责原生序列化。旧运行入口保持行为。

### Task 1: 成套快照存储

**Files:** Create `couplings/ibamr/scripts/checkpoint_store.py`; Test `couplings/ibamr/tests/test_checkpoint_store.py`.

**Interfaces:** `CheckpointStore(run: Path, keep: int = 2)`, `begin(required_bytes: int = 0) -> Path`, `publish(staging: Path, metadata: dict, required_files: list[str]) -> Path`, `select(which: str = 'latest') -> Path`, `prune() -> list[Path]`; `RunLock(run)` context manager. Manifest `format_version=1`, `snapshot_id`, `required_files`, `metadata` is the sole descriptor. Inventory contains all regular files with sizes, no hashes; files may be binary. `select` validates inventory and rejects corrupt latest without silent fallback. Required files are nonempty relative paths; no symlinks or special files anywhere in a managed snapshot. Staging names `.writing-NNNNNN`, published `snapshot-NNNNNN`. Only directories created by this store carrying its valid descriptor are cleanup candidates; unknown contents stop cleanup. Lock uses POSIX flock, held descriptor; Windows tests skip only POSIX-specific operations.

- [x] Add tests that fail before implementation: incomplete staging ignored; missing member publication rejected; latest corruption errors and previous works; three publications then prune retain last two; write/fsync/space failure preserves older snapshots; symlink and traversal rejected; file lock excludes second owner and releases on process death. Tests use temporary directories and real file contents, mock only fsync/disk failure.

```python
stage = store.begin()
(stage / 'learner').mkdir()
(stage / 'learner/state').write_bytes(b'weights')
saved = store.publish(stage, {'updates': 7}, ['learner/state'])
assert store.select() == saved
assert not stage.exists()
```

- [x] Run `python -m unittest discover -s couplings/ibamr/tests -p test_checkpoint_store.py -v`; implement bounded path validation, file/dir fsync, same-filesystem directory rename and checked cleanup; rerun only this file.
- [x] Review storage diff and commit only task files, leaving existing regrid edits untouched.

### Task 2: 原生 learner 活动状态与暂停

**Files:** Modify `source/smarties/Core/{Worker,Master,Agent}.*`, `source/smarties/Communicator.*`, `source/smarties/Learners/{Learner,Learner_approximator,RACER}.*`, `source/smarties/ReplayMemory/{MemoryBuffer,Episode,ReplayStatsCounters,Sampling}.*`, `source/smarties/Utils/DelayedReductor.h` only as needed; Create `source/smarties/Utils/TrainingCheckpoint.h`; Test `couplings/ibamr/tests/native_training_restart.cpp` and CMake registration.

**Interfaces:** Public `Communicator::saveAgentState(const std::string&) const`, `restoreAgentState(const std::string&)`. Opt-in `SMARTIES_PAIRED_CONTROL` directory. Supervisor writes `learner.request` containing absolute destination directory (already created); only after all proxies parked. Worker replies `learner.ready` with same destination on success or `learner.error` with message, and waits for request removal. Supervisor may create `learner.stop` before removing the request; then stop without another feedback, cancel idle master receives (no fabricated state), and return normally. Restore opt-in `SMARTIES_PAIRED_RESTORE` directory before application feedback and before training begins. Existing `--restart` remains unchanged for unpaired users. Snapshot at complete optimizer-update boundary, including warmup. No file-per-gradient change outside paired mode. Proxy calls finalizeProblemDescription before restoreAgentState; learner restores before spawning call handlers. Restrict initial support to single MPI learner, native VRACER, feed-forward network, uniform sampling, unshared action noise, no CMA or worker learners; check and reject other modes explicitly.

- [x] Write roundtrip test for Agent previous/current states, pending action/policy, episode count, RNG and cached Gaussian sample. Write replay test containing one completed and one active episode, checking the next CONT extends active state rather than reinitializes it. Run red on the native test target.

```cpp
saved.saveAgentState(path);
restored.restoreAgentState(path);
// Check the next action noise, not merely serialized text equality.
check(saved.sampleActionNoise() == restored.sampleActionNoise());
```

- [x] Add checked versioned native I/O owned by actual state classes. Save in-progress trajectories, exact counters without the ordinary save +1 convention, replay metadata/priorities, RNG/distributions, normalizers and running reducers; save networks/target/optimizer with exact optimizer step. Reject unsupported topology/algorithm rather than pretend general support. Check partial/truncated reads and failed writes. Pending caches either serialized or drained at the update boundary.
- [x] Quiesce algorithm and data tasks without waiting for new CFD observations once proxies parked. Restore before communication handlers start. Restore must not re-run warmup or clear loaded in-progress trajectories. File request errors produce explicit failure, not a ready marker. No MPI_Finalize ownership changes.
- [x] Build and run focused native state tests on node4; review and commit task files only.

### Task 3: CFD 与 proxy 边界恢复

**Files:** Modify `couplings/ibamr/cases/eel2d/{EelEnvironment,EelNearWallAdapter,EelExternalAdapter,EpisodeMailbox,IBEELKinematics,TailBeatPhase,EelControlTask}.*`; add focused restart tests under `couplings/ibamr/tests/`.

**Interfaces:** `EelEnvironment::writeRestart(directory)`, `initializeNearWall(..., restart_directory)`; restart step is read from the sidecar, which records loop/progress origin, phase/frequency and control history. Supervisor publishes slot `checkpoint.request` with destination; the proxy returns episode/sequence in `proxy.state`. Proxy consumes one CFD feedback, gets pending learner action, saves Agent and pending action, announces `proxy.ready`; it does not publish action until release. CFD recv loop accepts checkpoint request, all ranks write native restart collectively, publish `cfd.ready`; wait for release. Terminal slot records next episode pending, no CFD state needed. Restore sequence number is the saved feedback sequence; do not re-send that feedback to learner.

- [x] Add tail-phase/control roundtrip tests using noninitial frequency and accumulated phase, plus mailbox tests proving no duplicate saved feedback/action.

```cpp
// A restored control must rate-limit relative to the saved action, not 1.0.
check(restored.applyAction(next).applied_ratio == continuous.applyAction(next).applied_ratio);
```

- [x] Wire AppInitializer restart argv, register missing case-specific restart fields; preserve original numerical stepping order and regrid fix. Reset output folders only, not physical time, initial episode origin or RNG height. Keep restart interval zero in paired mode.
- [x] Build real CFD; compare controlled-action continuous versus resumed next interval using physical state tolerances, time and sequence exactness. Report numerical tolerances with evidence. Review and commit only new feature changes (include explicitly identified overlapping regrid dependency if required).

### Task 4: 统一入口、协调与真实恢复验收

**Files:** Create `couplings/ibamr/scripts/{run_near_wall.sh,paired_run.py}`, `couplings/ibamr/configs/paired-node4.json`; reuse `external_episode_manager.py` helpers without changing its old entry point; add `test_paired_run.py`; update Chinese README/runtime documentation.

**Interfaces:** `start --run --config [--checkpoint-minutes 30 --keep-checkpoints 2]`, `resume --run [--checkpoint previous]`, `stop --run`. JSON run config contains only whitelisted nonsecret fields; session outputs separate from immutable checkpoints. manager uses Task 1 store and Task 2/3 marker protocol. Resume gates release on every member restored, not arbitrary timers.

- [x] Write CLI tests: start refuses existing root, resume refuses no paired snapshot, previous selection, lock duplicate exclusion, config whitelist, cumulative budget no second full allocation, stop request atomic publication. Run red then implement. `stop` does not signal arbitrary stored PIDs.

```python
args = parse_args(['resume', '--run', str(run)])
assert args.command == 'resume'
assert args.checkpoint == 'latest'
```

- [x] Source configured IBAMR environment and invoke configured uv Python. New session on each restart. Complete cycle: request -> all proxy/CFD ready -> learner ready -> inventory/fsync/publish -> release or save-and-exit. Failed write leaves prior full snapshot, explicit failure status. First Ctrl+C equivalent to stop; repeated forced interruption does not claim saved.
- [x] Run one node4 two-environment/16-rank/8-thread save-stop-resume exercise with sufficient learner updates, no unrelated tests. Inspect saved/restored time, frequency, phase, trajectory and cumulative counters; verify later finite updates, normal termination and no residual MPI jobs. Inject one incomplete staging and verify old point selectable. Measure snapshot bytes and retain two.
- [x] Chinese documentation explains exact commands, peak disk three sets, lost interval on poweroff, no retroactive resume of old run. Do final scoped review, report proven results and remaining limitations. Do not automatically push GitHub.
