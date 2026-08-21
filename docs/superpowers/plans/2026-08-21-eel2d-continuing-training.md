# Eel2d Continuing Training Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** run multiple truncated Smarties replay segments and native CPU
learner updates inside one continuously advancing IBAMR eel2d simulation.

**Architecture:** `CouplingDriver` continues to own one MPI lifetime and the
eel callback continues to own one `EelEnvironment`. A small tested segment
tracker classifies ordinary transitions, logical-horizon truncations, and the
physical-time ceiling; `EelSmartiesAdapter` maps those classifications to
`sendState()` or `sendLastState()` without reconstructing IBAMR. The node3
launcher exposes exact update and physical-time budgets and the focused target
test verifies continuation, learner activity, checkpoint reload, and shutdown.

**Tech Stack:** C++14, Smarties native CPU VRACER/Adam, MPI/Open MPI, IBAMR
0.18.0, PETSc/SAMRAI/IBTK, CMake/CTest, Bash, GCC/G++ 8.5.0 on node3.

**Spec:**
`docs/superpowers/specs/2026-08-21-eel2d-continuing-training-design.md`

## Global Constraints

- `CouplingDriver` remains the only owner of `MPI_Init_thread()` and
  `MPI_Finalize()`.
- Smarties borrows the driver communicator; environment ranks alone initialize
  PETSc, SAMRAI, IBTK, and IBAMR on the environment communicator.
- One callback invocation initializes exactly one `EelEnvironment`; actions and
  logical segment boundaries never destroy or reconstruct it.
- Logical horizons use `sendLastState()`. This phase adds no absorbing physical
  terminal condition and therefore adds no speed-tracking `sendTermState()`.
- Check `terminateTraining()` after every state exchange and before receiving
  or applying another action.
- If IBAMR reaches its end time before Smarties ends training, publish the final
  truncated transition and then use the existing coordinated failure path;
  never return normally into a second launcher callback.
- Keep Smarties neural-network execution on the existing native CPU path. Do
  not add PyTorch, CUDA, pybind11, or Python bindings.
- Do not add a content hash, frozen contract, baseline, or admission gate. Do
  not remove the repository's existing source/runtime identity checks.
- Keep hypotheses and partial results under
  `.artifacts/ibamr-smarties-investigations/`; do not write to
  `experience/verified/` unless the existing admission checklist later passes
  in full.
- Run focused tests for changed behavior and directly related lifecycle/failure
  paths; do not rerun the unrelated 19-test collection.

---

### Task 1: Logical segment state machine

**Files:**

- Create: `couplings/ibamr/cases/eel2d/EelLogicalSegments.h`
- Create: `couplings/ibamr/cases/eel2d/EelLogicalSegments.cpp`
- Create: `couplings/ibamr/tests/test_eel_logical_segments.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**

- Consumes: positive `episode_decisions` from `EelTaskConfig` and the result of
  `EelEnvironment::stepsRemaining()` after each completed control interval.
- Produces:

```cpp
enum class EelTransitionKind
{
  continuing,
  logical_horizon,
  ibamr_end_time
};

struct EelLogicalStep
{
  unsigned segment;
  unsigned segment_decision;
  unsigned total_decisions;
  EelTransitionKind kind;
};

class EelLogicalSegments
{
public:
  explicit EelLogicalSegments(unsigned episode_decisions);
  unsigned beginSegment();
  EelLogicalStep completeDecision(bool ibamr_steps_remaining);
  bool segmentActive() const;
  unsigned completedSegments() const;
  unsigned totalDecisions() const;
};
```

- Invariants: a segment must be begun before a decision is completed; a second
  segment cannot begin while one is active; `ibamr_end_time` takes precedence
  over `logical_horizon` when both occur on the same decision; both boundary
  kinds close the active segment and increment `completedSegments()`.

- [ ] **Step 1: Write the failing state-machine test**

Create `test_eel_logical_segments.cpp` with direct assertions, including these
cases:

```cpp
#include "EelLogicalSegments.h"

#include <stdexcept>

int main()
{
  using namespace ibamr_smarties::eel2d;

  bool rejected_zero = false;
  try { EelLogicalSegments invalid(0); }
  catch (const std::invalid_argument&) { rejected_zero = true; }
  if (!rejected_zero) return 1;

  EelLogicalSegments segments(2);
  if (segments.beginSegment() != 1) return 2;
  const auto first = segments.completeDecision(true);
  if (first.segment != 1 || first.segment_decision != 1 ||
      first.total_decisions != 1 ||
      first.kind != EelTransitionKind::continuing) return 3;
  const auto first_boundary = segments.completeDecision(true);
  if (first_boundary.segment_decision != 2 ||
      first_boundary.kind != EelTransitionKind::logical_horizon ||
      segments.segmentActive() || segments.completedSegments() != 1) return 4;

  if (segments.beginSegment() != 2) return 5;
  const auto second = segments.completeDecision(false);
  if (second.segment != 2 || second.segment_decision != 1 ||
      second.total_decisions != 3 ||
      second.kind != EelTransitionKind::ibamr_end_time ||
      segments.completedSegments() != 2) return 6;
  return 0;
}
```

Register an `eel_logical_segments` target/test linked only to the existing
`ibamr_eel_control`. Do not list the still-missing implementation source in the
library during RED; configure must succeed and compilation must fail on the
missing public header.

- [ ] **Step 2: Run the test and verify RED**

Configure/build the existing test build on node3 or another configured
Smarties build, then run:

```bash
cmake --build . --target eel_logical_segments_test -j2
ctest --output-on-failure -R '^eel_logical_segments$'
```

Expected: the target fails to compile because `EelLogicalSegments.h` and the
declared API do not exist. A syntax or CMake registration error is not the
accepted RED result.

- [ ] **Step 3: Implement the minimum state machine**

Implement only the interface above. Store `episode_decisions_`,
`segments_started_`, `completed_segments_`, `segment_decisions_`,
`total_decisions_`, and `segment_active_`. `completeDecision()` increments
counters first, then selects:

```cpp
if (!ibamr_steps_remaining) kind = EelTransitionKind::ibamr_end_time;
else if (segment_decisions_ == episode_decisions_)
  kind = EelTransitionKind::logical_horizon;
else kind = EelTransitionKind::continuing;
```

Throw `std::logic_error` for calls in the wrong state and
`std::invalid_argument` for a zero horizon. Do not store CFD state, Smarties
objects, MPI communicators, or reset callbacks in this class.

At this point add `EelLogicalSegments.cpp` to `ibamr_eel_control`; the header is
found through that target's existing public eel2d include directory.

- [ ] **Step 4: Run the focused test and verify GREEN**

```bash
cmake --build . --target eel_logical_segments_test -j2
ctest --output-on-failure -R '^eel_logical_segments$'
```

Expected: one test passes and no IBAMR executable is rebuilt.

- [ ] **Step 5: Commit the state-machine slice**

```bash
git add couplings/ibamr/cases/eel2d/EelLogicalSegments.h \
  couplings/ibamr/cases/eel2d/EelLogicalSegments.cpp \
  couplings/ibamr/tests/test_eel_logical_segments.cpp \
  couplings/ibamr/CMakeLists.txt couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: classify continuing eel segments"
```

---

### Task 2: Long-lived eel adapter protocol

**Files:**

- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.h`
- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`
- Modify: `couplings/ibamr/tests/test_eel_control_protocol.cpp`
- Create: `couplings/ibamr/tests/test_eel_continuing_protocol.cmake`
- Create: `couplings/ibamr/tests/fixtures/speed_tracking_continuing.conf`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**

- Consumes: `EelLogicalSegments` from Task 1, the existing
  `EelEnvironment`, `EelControlTask`, and `smarties::Communicator` APIs.
- Produces the revised report:

```cpp
struct ControlProtocolReport
{
  unsigned completed_segments;
  unsigned completed_decisions;
  unsigned completed_ibamr_steps;
  unsigned clipped_actions;
  unsigned truncated_segments;
  unsigned environment_initializations;
  bool smarties_termination_received;
  bool finite_state_and_reward;
  unsigned state_dimension;
  unsigned action_dimension;
};
```

- Produces log records:

```text
EEL_CONTROL segment=<S> segment_decision=<D> decision=<T> ...
EEL_CONTROL_SEGMENT segment=<S> decisions=<D> total_decisions=<T> status=truncated reason=logical_horizon
EEL_CONTROL_COMPLETE segments=<S> decisions=<T> ibamr_steps=<N> truncated_segments=<K> stopped_by=smarties
```

- [ ] **Step 1: Write the RED integration assertion before changing the adapter**

Create `speed_tracking_continuing.conf` by copying the learner-activity
diagnostic values but setting `episode_decisions=2`. It remains explicitly
diagnostic and uncalibrated.

Create `test_eel_continuing_protocol.cmake` to launch one learner rank and one
single-rank environment with:

```text
--nMasters 1 --nThreads 1 --nEnvironments 1
--workerProcessesPerEnv 1 --learnersOnWorkers 0
--nTrainUpdates 1 --restart none --setupFolder .
--eel-mode speed-tracking --input-file input2d --task-file task.continuing.conf
```

The script must require exit code zero; at least two distinct
`EEL_CONTROL_SEGMENT` records; every segment record containing
`status=truncated`; strictly increasing `start_time`/`end_time` across all
`EEL_CONTROL` records; one constant nonzero `lagrangian_points` value; one
`EEL_CONTROL_COMPLETE ... stopped_by=smarties`; and both driver MPI lifecycle
markers. It must reject `EEL_CONTROL_TERMINAL` and a second environment
initialization. Store output under the CTest run directory, not `experience/`.

- [ ] **Step 2: Run the new script against the current node3 executable and verify RED**

Upload only the new CMake script and task fixture to the existing node3
investigation staging directory, then run the script against the currently
built `9998c0a`/`c9282b4`-ancestor eel executable. Supply the already rendered
medium `input2d`, current `settings.json`, and the existing Open MPI executable.

Use
`/data2/mjwu/local/coupling-build/smarties-ibamr-9ddac59b72f1/couplings/ibamr/ibamr_eel2d_smoke`
as the current executable and
`/data2/mjwu/local/coupling-staging/eel-continuing-red-c9282b4` as the RED run
directory. Expected: the application reaches its existing 30-second
`awaitTrainingTermination()` deadline, reports that speed-tracking did not
receive Smarties termination, and exits nonzero after printing one
`EEL_CONTROL_TERMINAL reason=episode_horizon` and zero
`EEL_CONTROL_SEGMENT` records. This known protocol-deadline failure is the
accepted RED result. Do not accept the outer CTest timeout, MPI launch error,
or missing input as RED.

- [ ] **Step 3: Replace the one-episode loop with a continuing loop**

Initialize `EelEnvironment` and warm up exactly where they are today. Construct
`EelLogicalSegments segments(config.episode_decisions)` after warmup and keep
`state`, `forward_velocity`, `task`, and `environment` outside both loops.
Implement this control shape:

```cpp
while (environment.stepsRemaining() && !comm->terminateTraining()) {
  const unsigned segment = segments.beginSegment();
  comm->sendInitState(asVector(state));
  if (comm->terminateTraining()) break;

  while (segments.segmentActive()) {
    const std::vector<double> action = comm->recvAction();
    // validate/apply action, advance one control interval, compute state/reward
    const EelLogicalStep step =
      segments.completeDecision(environment.stepsRemaining());

    if (step.kind == EelTransitionKind::continuing)
      comm->sendState(asVector(state), reward.total);
    else {
      comm->sendLastState(asVector(state), reward.total);
      ++control_protocol_report.truncated_segments;
    }

    // The exchange above may have delivered KILL. Never advance again first.
    if (comm->terminateTraining()) break;
    if (step.kind == EelTransitionKind::ibamr_end_time)
      throw std::runtime_error(
        "IBAMR end time reached before Smarties training termination");
  }
}
```

Set `environment_initializations=1` immediately after successful
`environment.initialize()`. Update cumulative report fields from the step
tracker and actual interval result. Print `EEL_CONTROL_SEGMENT` immediately
after `sendLastState()` and print `EEL_CONTROL_COMPLETE` only after Smarties
termination is observed. Remove `awaitTrainingTermination()` from
speed-tracking mode; retain it unchanged for smoke mode.

Do not call `environment.shutdown()` inside either loop. Do not reset
`EelControlTask`, frequency ratio, tail phase, time, hierarchy, or flow state at
a logical boundary.

- [ ] **Step 4: Update the C++ protocol assertion**

Change `test_eel_control_protocol.cpp` to all-reduce a valid report from the one
environment application root with these conditions:

```cpp
const int local_valid =
  report.smarties_termination_received &&
  report.completed_segments >= 1 &&
  report.truncated_segments == report.completed_segments &&
  report.completed_decisions >= report.completed_segments &&
  report.completed_ibamr_steps >= report.completed_decisions &&
  report.environment_initializations == 1 &&
  report.finite_state_and_reward &&
  report.state_dimension == 5 && report.action_dimension == 1 ? 1 : 0;
```

Preserve the checks that MPI is active after `driver.run()` and finalized only
after `CouplingDriver` destruction.

- [ ] **Step 5: Build once and verify GREEN with focused tests**

```bash
cmake --build . --target eel_control_protocol ibamr_eel2d_smoke -j2
ctest --output-on-failure \
  -R '^(eel_logical_segments|eel_control_protocol|eel_continuing_protocol)$'
```

Expected: all three tests pass. Inspect the continuing output and confirm the
first transition of segment 2 starts at the same physical time at which
segment 1 ended; later transitions must advance beyond it.

- [ ] **Step 6: Run the directly affected failure path**

```bash
ctest --output-on-failure -R '^eel_smoke_failure_after_mpi$'
```

Then execute the continuing test once with a rendered `END_TIME` too short to
reach Smarties' update budget. Expected: it logs one final truncated boundary,
prints `IBAMR end time reached before Smarties training termination`, exits
nonzero through coordinated MPI failure, starts no second callback, and leaves
no run-scoped `ibamr_eel2d_smoke`, `mpiexec`, `orted`, or `prterun` process.

- [ ] **Step 7: Commit the adapter slice**

```bash
git add couplings/ibamr/cases/eel2d/EelSmartiesAdapter.h \
  couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp \
  couplings/ibamr/tests/test_eel_control_protocol.cpp \
  couplings/ibamr/tests/test_eel_continuing_protocol.cmake \
  couplings/ibamr/tests/fixtures/speed_tracking_continuing.conf \
  couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: continue eel training across logical segments"
```

---

### Task 3: Exact update and simulation-time launcher controls

**Files:**

- Modify: `couplings/ibamr/scripts/run_node3.sh`
- Modify: `couplings/ibamr/scripts/render_input.cmake`
- Modify: `couplings/ibamr/tests/test_node3_scripts.sh`
- Modify: `couplings/ibamr/tests/test_render_input.cmake`
- Modify: `couplings/ibamr/tests/test_eel_learner_activity.cmake`
- Modify: `couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf`
- Modify: `couplings/ibamr/README.md`

**Interfaces:**

- `run_node3.sh train --train-updates N` passes
  `--nTrainUpdates N --nTrainSteps 0`.
- `run_node3.sh train --train-steps N` retains the existing transition-step
  meaning and passes `--nTrainSteps N --nTrainUpdates 0`.
- The two budget options are mutually exclusive when explicitly supplied; the
  default remains `--train-steps 1` for compatibility.
- `run_node3.sh ... --end-time T` accepts a positive finite decimal, defaults
  to `10.0`, passes `-DEEL_END_TIME=T` to `render_input.cmake`, and records
  `simulation_end_time=T` in `manifest.txt`.
- `render_input.cmake` requires `EEL_END_TIME` and replaces only the top-level
  `END_TIME = ...` assignment; the two integrator blocks continue to refer to
  the `END_TIME` symbol.

- [ ] **Step 1: Add RED launcher fixtures**

Extend `test_node3_scripts.sh` with assertions that currently fail:

```bash
output=$(bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
  --learner-threads 2 --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-updates 2 --end-time 12.5)
assert_contains "$output" "--nTrainSteps 0"
assert_contains "$output" "--nTrainUpdates 2"
assert_contains "$output" "SIMULATION_END_TIME=12.5"
```

Add a negative fixture that supplies both `--train-steps 1` and
`--train-updates 2` and expects `choose exactly one training budget`. Replace
the old “step budget unreachable in one physical episode” negative fixture
with a positive dry-run using a budget larger than `episode_decisions`; it must
now reach `COMMAND=`.

Extend `test_render_input.cmake` to render with `EEL_END_TIME=12.5`, require
exactly one top-level `END_TIME = 12.5`, and verify both integrator references
still say `end_time = END_TIME`.

- [ ] **Step 2: Run fixture tests and verify RED**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
cmake -P couplings/ibamr/tests/test_render_input.cmake
```

Expected: node3 script fixture rejects unknown `--train-updates` or
`--end-time`; renderer fixture fails because `EEL_END_TIME` is ignored. Fix
fixture setup mistakes until these are the only failures.

- [ ] **Step 3: Implement budget parsing without reinterpreting counters**

Track `train_steps_explicit`, `train_updates_explicit`, `train_steps`, and
`train_updates` separately. Validate explicit values as positive integers.
Reject both explicit options together. For default/step mode set
`effective_train_steps=$train_steps` and `effective_train_updates=0`; for
update mode set them to `0` and `$train_updates`. Always pass both Smarties
flags so the manifest command is unambiguous.

Remove only the old `maximum_single_episode_train_steps` calculation and its
rejection. Retain task structure, batch/thread divisibility, fidelity, source,
runtime identity, and learner/environment topology validation.

- [ ] **Step 4: Implement explicit end-time rendering**

Validate `--end-time` with a decimal/scientific-number regular expression and
an `awk` comparison that rejects zero, negative, NaN, and infinity. Pass it in
both the dry-run and real render command:

```bash
cmake -D"FIDELITY_FILE=$config" \
  -D"EEL_END_TIME=$simulation_end_time" \
  -D"OUTPUT_FILE=$output" -P "$render_script"
```

In `render_input.cmake`, add `EEL_END_TIME` validation before
`configure_file()` and a targeted multiline replacement for the single
top-level assignment. Fail if the replacement count is not one.

- [ ] **Step 5: Migrate the focused learner-activity wrapper**

Set `episode_decisions=2` in
`speed_tracking_learner_activity.conf`. Change the opt-in node3 learner test
registration and launcher gate from `--train-steps 1` to
`--train-updates 2`. Update `test_eel_learner_activity.cmake` to require:

- exactly two finite `stage=update` audit records with steps 1 and 2;
- a final optimizer step of 2;
- at least two truncated `EEL_CONTROL_SEGMENT` records;
- no `EEL_CONTROL_TERMINAL` record;
- exactly one `EEL_CONTROL_COMPLETE ... stopped_by=smarties`;
- constant `lagrangian_points=2932` for the existing medium fixture;
- checkpoint restart digest equal to the training final digest;
- zero exit codes and empty process snapshots.

Update the fake executable in `test_node3_scripts.sh` to emit those exact
records and a two-update audit, so the script fixture continues to test the
real wrapper rather than bypassing it.

- [ ] **Step 6: Update documentation and manifests**

In `couplings/ibamr/README.md`, replace the one-physical-episode limitation
with the continuing-task semantics. Document both training counters, the
default `--end-time 10.0`, premature-end failure, and the fact that a logical
segment is not an independent reset. Keep the policy-quality, calibration,
PyTorch/CUDA, and independent-reset limitations explicit.

Write `train_steps`, `train_updates`, `train_budget_kind`, and
`simulation_end_time` to each run manifest and print the same derived values
before `COMMAND=`.

- [ ] **Step 7: Verify GREEN without building IBAMR**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
cmake -P couplings/ibamr/tests/test_render_input.cmake
bash -n couplings/ibamr/scripts/run_node3.sh
git diff --check
```

Expected: all fixture/syntax checks pass. These are script tests and must not
trigger an IBAMR compile.

- [ ] **Step 8: Commit the launcher slice**

```bash
git add couplings/ibamr/scripts/run_node3.sh \
  couplings/ibamr/scripts/render_input.cmake \
  couplings/ibamr/tests/test_node3_scripts.sh \
  couplings/ibamr/tests/test_render_input.cmake \
  couplings/ibamr/tests/test_eel_learner_activity.cmake \
  couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  couplings/ibamr/README.md
git commit -m "feat: launch continuing eel update budgets"
```

---

### Task 4: Focused node3 continuation and learner verification

**Files:**

- Create ignored evidence under the PowerShell-computed path
  `.artifacts/ibamr-smarties-investigations/eel-continuing-$revision/`.
- Do not modify `experience/verified/` in this task.

**Interfaces:**

- Consumes: committed clean revision from Tasks 1-3, existing
  `package_local.ps1`, `build_node3.sh`, and `run_node3.sh` workflows.
- Produces: a node3 investigation containing commands, exact revision,
  environment/topology, focused test logs, learner audit, segment/control
  logs, checkpoint-reload result, failure-path result, scoped process
  snapshots, and an explicit claim boundary.

- [ ] **Step 1: Verify the local source state and package it**

```powershell
git status --short --branch
$revision = git rev-parse --short=12 HEAD
& .\couplings\ibamr\scripts\package_local.ps1 `
  -Repository . `
  -OutputDirectory ".artifacts\packages\eel-continuing-$revision"
```

Expected: tracked state is clean before packaging. Existing package metadata
and manifests remain in use; this task adds no new identity mechanism.

- [ ] **Step 2: Upload and build only the required targets on node3**

After `revision=$(git rev-parse --short=12 HEAD)` on the extracted source, set:

```bash
source="/data2/mjwu/local/coupling-src/smarties-ibamr-$revision"
build="/data2/mjwu/local/coupling-build/smarties-ibamr-$revision"
```

Source `/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh`; confirm GCC/G++
8.5.0 and the matching MPI wrappers; configure with `SINGLE_PRECISION=ON` and
`COMPILE_PY_SO=OFF`; then build only:

```bash
cmake --build "$build" --target \
  eel_logical_segments_test eel_control_protocol ibamr_eel2d_smoke \
  smarties_cpu_learner_environment -j2
```

- [ ] **Step 3: Run the focused nonphysical and protocol tests**

```bash
ctest --test-dir "$build" --output-on-failure \
  -R '^(eel_logical_segments|eel_control_protocol|eel_continuing_protocol|node3_scripts)$'
```

Expected: four tests pass. Do not run the unrelated full test set.

- [ ] **Step 4: Run the medium-fidelity continuation target**

From the immutable node3 source, run:

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --source "$source" --build "$build" \
  --envs 1 --ranks-per-env 2 --learner-ranks 1 --learner-threads 2 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-updates 2 --end-time 10.0
```

Expected: the run crosses at least two logical segment boundaries, records
exactly two finite native CPU optimizer updates, keeps one constant nonzero
global Lagrangian point count, advances physical time monotonically, reloads
the final checkpoint into the bounded synthetic evaluation, returns through
`CouplingDriver`, and leaves empty scoped process snapshots. Runtime duration
is recorded but is not a correctness threshold.

- [ ] **Step 5: Run one directly relevant premature-end failure**

Repeat the same command with `--end-time 0.13` and `--train-updates 2` in an
isolated run directory. Expected: one final truncated transition is published;
the error states that IBAMR ended before Smarties; no second callback starts;
MPI exits nonzero through the coordinated fatal path; and the scoped residual
snapshot is empty.

Do not repeat the already passing generic fault-after-initialize run unless the
adapter change alters that test's focused result. The registered
`eel_smoke_failure_after_mpi` check from Task 2 is the regression coverage.

- [ ] **Step 6: Inspect evidence and record the bounded conclusion**

Create `investigation.md` under the ignored investigation directory with:

- exact Git revision and node3 source/build/run paths;
- compiler, MPI, IBAMR/PETSc/SAMRAI overlay identity already emitted by the
  launcher;
- rank topology: one learner rank, one two-rank IBAMR environment, two learner
  threads, `learnersOnWorkers=0`;
- commands and exit statuses;
- segment count, total decisions, actual start/end physical time, update count,
  finite audit result, checkpoint digest comparison, and Lagrangian count;
- normal and premature-end process snapshots;
- limitations: no independent reset, no calibrated target, no policy-quality
  or long-duration stability claim, no PyTorch/CUDA.

Keep status `OPEN` unless every experience-admission item is independently
reviewed and repeated target evidence exists. Do not promote this result merely
because the focused run passes.

- [ ] **Step 7: Run final source checks and stop for review**

```bash
git status --short --branch
git diff --check HEAD~3..HEAD
```

Report the exact focused results and artifact paths. Do not merge, push, or
write an experience record until the user reviews this stage.

## Plan self-review result

- Every design requirement maps to Tasks 1-4.
- Production changes are preceded by a test that fails for the missing
  behavior.
- The only new pure C++ component is the segment classifier needed to prevent
  off-by-one and boundary-precedence errors.
- Smarties core, MPI ownership, network backend, geometry, checkpoint format,
  and existing identity checks are unchanged.
- The target run uses two learner threads and two IBAMR ranks but treats runtime
  only as an observation, never a pass/fail condition.
