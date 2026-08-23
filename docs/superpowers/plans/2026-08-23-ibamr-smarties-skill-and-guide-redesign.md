# IBAMR-Smarties Skill and Guide Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the eel2d-centered coupling guidance with a concise reusable IBAMR-Smarties skill and a complete Chinese node3 installation-to-operation manual.

**Architecture:** Keep cross-case invariants and routing in `SKILL.md`, move generic case-porting mechanics and verified lessons into focused references, and retain eel2d as one bounded implementation reference. Keep machine-specific paths, commands, parameters, and output behavior in the Chinese operator guide.

**Tech Stack:** Markdown, Git, PowerShell, Bash/CMake launcher inspection, Codex skill frontmatter validation.

**Spec:** `docs/superpowers/specs/2026-08-23-ibamr-smarties-skill-and-guide-redesign.md`

## Global Constraints

- Preserve `CouplingDriver` as the sole owner of `MPI_Init_thread()` and `MPI_Finalize()`.
- Preserve Smarties borrowed-MPI semantics and dedicated learner/environment ranks.
- Keep PyTorch, CUDA, pybind11, and Python bindings outside the documented current coupling path.
- Treat eel2d policy quality, long-run stability, two 16-rank environments, physical reset, and non-0.18.0 compatibility as unverified.
- Promote no new record into `experience/verified/` in this documentation-only change.
- Do not modify or stage `docs/superpowers/plans/2026-08-03-node3-smarties-uv-install.md`.
- Use `apply_patch` for every tracked-file edit.

---

### Task 1: Rewrite the generic skill entry and references

**Files:**
- Modify: `.agents/skills/ibamr-smarties-coupling/SKILL.md`
- Modify: `.agents/skills/ibamr-smarties-coupling/references/architecture-contract.md`
- Create: `.agents/skills/ibamr-smarties-coupling/references/case-porting-playbook.md`
- Create: `.agents/skills/ibamr-smarties-coupling/references/validated-lessons.md`
- Read only: `.agents/skills/ibamr-smarties-coupling/references/experience-admission.md`

**Interfaces:**
- Consumes: the fixed MPI architecture and evidence-admission rules in the current skill.
- Produces: a short case-independent entrypoint that routes architecture, case porting, validated lessons, eel2d details, and experience admission to separate references.

- [ ] **Step 1: Capture the current generic guidance before editing**

Run:

```powershell
Get-Content -Raw .agents\skills\ibamr-smarties-coupling\SKILL.md
Get-Content -Raw .agents\skills\ibamr-smarties-coupling\references\architecture-contract.md
Get-Content -Raw .agents\skills\ibamr-smarties-coupling\references\experience-admission.md
```

Expected: MPI ownership, communicator boundaries, shutdown ordering, CPU baseline, and experience-admission rules are all present.

- [ ] **Step 2: Rewrite `SKILL.md` as the generic decision entrypoint**

Use `apply_patch`. Retain the existing `name`; change the description to trigger on any IBAMR-Smarties design, implementation, port, review, debugging, installation, or documentation task. The body must contain exactly these decision areas:

1. reference routing;
2. fixed process and communicator invariants;
3. generic case integration sequence;
4. synchronous control-point rule;
5. normal and fatal shutdown rule;
6. staged verification and experience admission.

Do not include node3 absolute paths, eel2d state/reward details, or validation numbers.

- [ ] **Step 3: Tighten `architecture-contract.md`**

Use `apply_patch` to remove repeated explanatory prose while retaining:

- one MPI job and one driver-owned MPI lifetime;
- learner and environment rank partition;
- environment communicator assignment to PETSc/SAMRAI/IBTK/IBAMR;
- no post-MPI `fork()`;
- blocking safe-point action exchange;
- inside-out normal destruction and coordinated `MPI_Abort` for unrecoverable distributed failure.

- [ ] **Step 4: Create `case-porting-playbook.md`**

Use `apply_patch`. Define this reusable transformation of an official IBAMR case:

```text
official example main loop
  -> thin main: mode selection + CouplingDriver
  -> CaseEnvironment: initialize, observe, apply action, advance interval, reset/shutdown
  -> CaseSmartiesAdapter: dimensions, protocol, state, action, reward, terminal handling
  -> case-specific control implementation
```

Include required decisions for state, action bounds, control cadence, reward units, solver-safe terminal conditions, physical reset capability, output volume, and version-specific dependency patches. State that `recvAction()` blocks at a safe point and no CFD time advances until the action returns.

- [ ] **Step 5: Create `validated-lessons.md`**

Use `apply_patch`. Record only conclusions supported by current code and bounded node3 evidence:

- borrowed MPI prevents dual finalization;
- every CFD library must see the environment communicator;
- hard-coded `MPI_COMM_WORLD` in a dependency can deadlock subcommunicator coupling;
- an IBAMR action boundary is a synchronous pause, not process destruction;
- logical RL segmentation and physical CFD reset are independent concepts;
- source/build/runtime identities and process cleanup are required evidence;
- long runs require explicit transition, visualization, restart, and checkpoint output policies.

For each conclusion, state the portability boundary. Do not claim a new `experience/verified` admission.

- [ ] **Step 6: Check Task 1 structure**

Run:

```powershell
rg -n "node3|eel2d|2932|reward|6\.28|/data2" .agents\skills\ibamr-smarties-coupling\SKILL.md
rg -n "MPI_Init_thread|MPI_Finalize|PETSC_COMM_WORLD|recvAction|MPI_Abort|physical reset" .agents\skills\ibamr-smarties-coupling
git diff --check -- .agents\skills\ibamr-smarties-coupling
```

Expected: the first command returns no matches; the second finds every invariant in the entrypoint or generic references; `git diff --check` exits zero.

---

### Task 2: Consolidate the eel2d implementation reference

**Files:**
- Create: `.agents/skills/ibamr-smarties-coupling/references/eel2d-reference.md`
- Delete: `.agents/skills/ibamr-smarties-coupling/references/eel2d-continuing-coupling.md`
- Delete: `.agents/skills/ibamr-smarties-coupling/references/eel2d-ibamr-case-map.md`
- Modify: `.agents/skills/ibamr-smarties-coupling/SKILL.md`

**Interfaces:**
- Consumes: eel2d provenance, code responsibilities, control protocol, reward formula, logical segment semantics, and bounded node3 evidence from the two existing eel references.
- Produces: one eel2d-only reference linked from the generic skill.

- [ ] **Step 1: Verify eel2d facts against source**

Run:

```powershell
rg -n "recvAction|setTailBeatFrequencyRatio|advanceControlInterval|sendState|sendLastState|terminateTraining" couplings\ibamr\cases\eel2d\EelSmartiesAdapter.cpp
rg -n "PETSC_COMM_WORLD|SAMRAI_MPI::setCommunicator|advanceHierarchy|currentCenterOfMass" couplings\ibamr\cases\eel2d\EelEnvironment.cpp
rg -n "PHI|OMEGA|setTailBeatFrequencyRatio|getTailBeatPhase" couplings\ibamr\cases\eel2d\upstream\IBEELKinematics.cpp couplings\ibamr\cases\eel2d\upstream\input2d.in
rg -n "makeState|reward|controlInterval|official_omega0" couplings\ibamr\cases\eel2d\EelControlTask.cpp
```

Expected: every documented control, observation, reward, phase, and communicator statement has a matching source location.

- [ ] **Step 2: Create the consolidated reference**

Use `apply_patch` to create `eel2d-reference.md` with these sections:

1. verified source provenance and version;
2. file responsibility map;
3. action wait/apply/advance/return sequence;
4. five-state, one-action definition and exact reward formula;
5. continuous phase and unchanged vertex boundary;
6. logical segment versus physical environment semantics;
7. bounded node3 validation facts;
8. explicit unverified boundaries.

Write conclusions directly. Do not include investigation narration.

- [ ] **Step 3: Replace old eel references**

Use `apply_patch` to delete the two old files and update `SKILL.md` so eel2d work routes only to `references/eel2d-reference.md`.

- [ ] **Step 4: Verify no stale reference remains**

Run:

```powershell
rg -n "eel2d-continuing-coupling|eel2d-ibamr-case-map" .agents couplings docs experience
Test-Path .agents\skills\ibamr-smarties-coupling\references\eel2d-reference.md
git diff --check -- .agents\skills\ibamr-smarties-coupling
```

Expected: no old filename match, `Test-Path` returns `True`, and diff check exits zero.

---

### Task 3: Rewrite the Chinese installation and operation manual

**Files:**
- Modify: `couplings/ibamr/README.zh-CN.md`
- Modify only if the existing link is missing or stale: `couplings/ibamr/README.md`

**Interfaces:**
- Consumes: `package_local.ps1`, `prepare_node3_ibamr.sh`, `build_node3.sh`, `run_node3.sh`, current training/task files, eel2d source, and Smarties persistence behavior.
- Produces: a linear Chinese operator manual from source acquisition to result interpretation.

- [ ] **Step 1: Freeze script and parameter facts**

Run:

```powershell
Get-Content -Raw couplings\ibamr\scripts\package_local.ps1
Get-Content -Raw couplings\ibamr\scripts\prepare_node3_ibamr.sh
Get-Content -Raw couplings\ibamr\scripts\build_node3.sh
bash couplings/ibamr/scripts/run_node3.sh --help
```

If `bash` cannot execute in the Windows environment, use:

```powershell
Get-Content couplings\ibamr\scripts\run_node3.sh -TotalCount 270
```

Expected: all documented defaults, required files, version checks, build outputs, and launcher constraints are taken from current scripts.

- [ ] **Step 2: Rewrite `README.zh-CN.md`**

Use `apply_patch` to replace the current manual with these sections in order:

1. supported scope and exact verified toolchain;
2. Git clone and immutable package upload procedures;
3. dependency inventory and preflight commands;
4. SAMRAI patch purpose, automatic overlay preparation, reuse marker, and version boundary;
5. build command, build outputs, `BUILD_JOBS`, and absence of a global Smarties install step;
6. smoke command and coupled training command;
7. parameter table covering `--source`, `--build`, `--envs`, `--ranks-per-env`, `--learner-ranks`, `--learner-threads`, `--fidelity`, `--training`, `--task`, `--smoke-steps`, `--train-steps`, `--train-updates`, `--end-time`, `--fault-after-initialize`, and `--dry-run`;
8. total-rank formula and distinction between IBAMR MPI ranks and learner CPU threads;
9. action blocking, application, CFD interval advancement, state/reward return, and logical segment behavior;
10. eel2d state/action/reward formula and diagnostic configuration boundary;
11. in-memory replay limit, transition logging, network/scaling/replay checkpoints, learner audit, stdout, VisIt/Silo, IBAMR restart, and manifest locations;
12. output policy required before long training;
13. normal completion, IBAMR-end-time failure, process cleanup, and common diagnostic messages;
14. checklist for a new IBAMR case and another IBAMR/SAMRAI version.

Use complete runnable commands. Use no first-person discussion, design debate, or speculative language.

- [ ] **Step 3: Cross-check persistence claims**

Run:

```powershell
rg -n "logAllSamples|learnerAuditDir|saveFreq|maxTotObsNum" source\smarties couplings\ibamr\configs couplings\ibamr\scripts
rg -n "viz_dump_interval|restart_dump_interval|data_dump_interval|timer_dump_interval|output_interval" couplings\ibamr\cases\eel2d\upstream\input2d.in
rg -n "agent_.*obs|cumulative_rewards|MemoryBuffer::save|saveAuditCheckpoint" source\smarties
```

Expected: every output and storage statement in the manual is traceable to current code or configuration.

- [ ] **Step 4: Check manual consistency**

Run:

```powershell
rg -n "可能|大概|我认为|建议考虑|之后再说|TODO|TBD|FIXME" couplings\ibamr\README.zh-CN.md
rg -n "README.zh-CN.md" couplings\ibamr\README.md
git diff --check -- couplings\ibamr\README.zh-CN.md couplings\ibamr\README.md
```

Expected: the first command returns no matches, the English README links the Chinese manual, and diff check exits zero.

---

### Task 4: Validate the skill as a reusable reference

**Files:**
- Verify: `.agents/skills/ibamr-smarties-coupling/SKILL.md`
- Verify: `.agents/skills/ibamr-smarties-coupling/references/*.md`
- Verify: `couplings/ibamr/README.zh-CN.md`

**Interfaces:**
- Consumes: all rewritten documentation from Tasks 1-3.
- Produces: evidence that the skill routes a non-eel case correctly and does not overclaim compatibility or validation.

- [ ] **Step 1: Run the bundled skill validator**

Run from PowerShell with an available real Python interpreter:

```powershell
$validator='C:\Users\wumj\.codex\skills\.system\skill-creator\scripts\quick_validate.py'
python $validator .agents\skills\ibamr-smarties-coupling
```

Expected: validator reports the skill is valid. If the WindowsApps Python alias cannot start, record that exact failure and run Step 2 instead; do not claim the bundled validator passed.

- [ ] **Step 2: Run equivalent structural checks**

Run:

```powershell
$skill='.agents\skills\ibamr-smarties-coupling'
$entry=Get-Content -Raw "$skill\SKILL.md"
$entry -match '(?s)^---\r?\nname: ibamr-smarties-coupling\r?\ndescription: .+?\r?\n---'
Get-ChildItem "$skill\references" -File | Select-Object -ExpandProperty Name
rg -n "TODO|TBD|FIXME|<placeholder>" $skill
```

Expected: frontmatter check is `True`; all five references exist; unfinished-marker search returns no match.

- [ ] **Step 3: Apply three forward scenarios**

Read the skill and answer each scenario using only its routing and references:

1. Port an IBAMR cylinder-control official example with one pressure-probe state and one boundary-control action.
2. Diagnose a new case that hangs during AMR regridding when learner ranks are present.
3. Prepare an IBAMR 0.20 port without assuming the 0.18.0 SAMRAI patch applies.

For each answer, verify it identifies MPI ownership, environment communicator, action safe point, case-specific adapter work, shutdown behavior, and validation boundary. The third answer must require source inspection and a new overlay rather than claiming compatibility.

- [ ] **Step 4: Run repository-wide reference and formatting checks**

Run:

```powershell
rg -n "eel2d-continuing-coupling|eel2d-ibamr-case-map" .agents couplings experience
git diff --check
git status --short
```

Expected: no stale reference match; `git diff --check` exits zero; status contains only intended documentation changes plus the preserved untracked installation-plan file.

---

### Task 5: Commit and publish the redesign

**Files:**
- Commit: `.agents/skills/ibamr-smarties-coupling/**`
- Commit: `couplings/ibamr/README.zh-CN.md`
- Commit only if changed: `couplings/ibamr/README.md`
- Commit: `docs/superpowers/plans/2026-08-23-ibamr-smarties-skill-and-guide-redesign.md`

**Interfaces:**
- Consumes: verified documentation changes.
- Produces: one reviewable local commit and an updated GitHub `feature/ibamr-eel2d-coupling` branch.

- [ ] **Step 1: Review the exact staged set**

Run:

```powershell
git status --short
git diff -- .agents/skills/ibamr-smarties-coupling couplings/ibamr/README.zh-CN.md couplings/ibamr/README.md docs/superpowers/plans/2026-08-23-ibamr-smarties-skill-and-guide-redesign.md
```

Expected: no source code, test code, runtime artifact, evidence artifact, or `2026-08-03-node3-smarties-uv-install.md` change is included.

- [ ] **Step 2: Commit the redesign**

Run:

```powershell
git add .agents/skills/ibamr-smarties-coupling couplings/ibamr/README.zh-CN.md couplings/ibamr/README.md docs/superpowers/plans/2026-08-23-ibamr-smarties-skill-and-guide-redesign.md
git commit -m "docs: generalize IBAMR coupling guidance"
```

Expected: one commit containing only the intended documentation paths.

- [ ] **Step 3: Verify the commit before publishing**

Run:

```powershell
git show --check --stat --oneline HEAD
git status --short
```

Expected: commit check exits zero; only the preserved untracked installation-plan file remains.

- [ ] **Step 4: Push the current branch**

Run with the configured local proxy if direct GitHub access fails:

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin feature/ibamr-eel2d-coupling
```

Expected: remote branch advances to the redesign commit without force-push.
