# eel2d Tail-Beat Frequency Control Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task. Before every implementation session, read `.agents/skills/ibamr-smarties-coupling/SKILL.md`, `references/architecture-contract.md`, and `references/experience-admission.md` completely.

**Goal:** Turn the verified eel2d lifecycle probe into a one-action, five-state, target-speed-tracking coupling in which Smarties controls the official IBAMR eel's tail-beat frequency for one multi-decision episode.

**Architecture:** Keep one driver-owned MPI lifecycle and isolated learner/environment rank roles. Add a callback-count-independent phase controller to the vendored official kinematics, let `EelEnvironment` apply commands and own the multi-CFD-step control interval, and keep action mapping, normalization, and reward calculation in a pure task model used by the Smarties adapter. Preserve the existing smoke path as a regression test while adding an explicitly stage-two speed-tracking path.

**Tech Stack:** C++14, MPI/Open MPI, Smarties native CPU learner, IBAMR 0.18.0, PETSc/SAMRAI/IBTK, CMake/CTest, Bash, PowerShell packaging, node3 GCC/G++ 8.5.0.

---

## Preconditions and fixed decisions

- Start from `feature/ibamr-eel2d-coupling` at or after design commit `6677cff`.
- Implement on a new isolated branch/worktree, for example
  `feature/eel2d-frequency-control` in `.worktrees/eel2d-frequency-control`.
- Do not modify the user's untracked
  `docs/superpowers/plans/2026-08-03-node3-smarties-uv-install.md`.
- Do not modify the shared node3 IBAMR installation.
- Preserve the official angular frequency exactly as
  `omega0 = 0.785 / 0.125 = 6.28`; do not replace it with exact `2*pi`.
- One action controls the applied frequency ratio. The default range is
  `[0.5, 1.5]`, with maximum ratio change `0.1` per decision.
- One nominal control interval is `2*pi/(8*omega0)`.
- The initial learning task is forward target-speed tracking.
- Physical reset, PyTorch, CUDA, GPU training, amplitude control, steering,
  and physical-energy claims are out of scope.
- Unverified evidence stays under `.artifacts`; `experience/verified` is only
  updated after the complete node3 admission matrix passes for one revision.

## Task 1: Establish the isolated implementation workspace and architecture gate

**Files:**

- Read: `.agents/skills/ibamr-smarties-coupling/SKILL.md`
- Read: `.agents/skills/ibamr-smarties-coupling/references/architecture-contract.md`
- Read: `.agents/skills/ibamr-smarties-coupling/references/experience-admission.md`
- Create locally: `.artifacts/stage2/architecture-checklist.txt`

**Step 1: Verify the starting revision and worktree state**

Run:

```powershell
git branch --show-current
git log -1 --oneline
git status --short
git worktree list
```

Expected: the design commit is reachable, and the only unrelated local item is
the known node3 installation plan.

**Step 2: Create an isolated branch/worktree**

Run from the main Smarties worktree:

```powershell
git worktree add .worktrees/eel2d-frequency-control -b feature/eel2d-frequency-control
```

Expected: all code edits occur in the new worktree. Existing user work remains
unchanged.

**Step 3: Record the architecture checklist**

Create an untracked `.artifacts/stage2/architecture-checklist.txt` containing:

```text
driver_is_only_mpi_owner=yes
smarties_borrows_world_comm=yes
learner_environment_ranks_isolated=yes
environment_only_initializes_ibamr=yes
petsc_comm_bound_before_ibtk=yes
no_fork_after_mpi_init=yes
ibamr_owns_cfd_loop=yes
cpu_smarties_only=yes
experience_requires_full_admission=yes
```

Do not commit this artifact.

**Step 4: Baseline verification**

Run the existing script-only tests before edits:

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
cmake -DCOUPLING_ROOT="$PWD/couplings/ibamr" \
  -P couplings/ibamr/tests/test_render_input.cmake
```

Expected: PASS. If either fails, stop and use `superpowers:systematic-debugging`
before changing feature code.

No commit is required for this task.

## Task 2: Add a pure, callback-count-independent phase controller

**Files:**

- Create: `couplings/ibamr/cases/eel2d/TailBeatPhase.h`
- Create: `couplings/ibamr/cases/eel2d/TailBeatPhase.cpp`
- Create: `couplings/ibamr/tests/test_tail_beat_phase.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Step 1: Write the failing unit test**

Test the following contract without linking IBAMR:

```cpp
using ibamr_smarties::eel2d::TailBeatPhase;

TailBeatPhase phase(6.28, 0.0);
CHECK_NEAR(phase.valueAt(0.25), 6.28 * 0.25, 1e-14);
CHECK_NEAR(phase.angularFrequency(), 6.28, 1e-14);

const double switching_time = 0.4;
const double before = phase.valueAt(switching_time);
phase.setFrequencyRatio(1.25, switching_time);
CHECK_NEAR(phase.valueAt(switching_time), before, 1e-14);
CHECK_NEAR(phase.valueAt(0.5), before + 6.28 * 1.25 * 0.1, 1e-14);
```

Also test:

- repeated `valueAt(t)` calls return the same value;
- changing callback/query count does not advance phase;
- a second switch remains continuous;
- zero, negative, NaN, or infinite ratios throw `std::invalid_argument`;
- a command time older than the anchor throws `std::logic_error`;
- a query time older than the anchor is rejected instead of extrapolated
  silently.

**Step 2: Register and run the test to confirm failure**

Add the test target to the coupling CMake files, then run on the configured
node3 build:

```bash
cmake --build /data2/mjwu/local/coupling-build/<snapshot> \
  --target tail_beat_phase_test -j2
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R '^tail_beat_phase$' --output-on-failure
```

Expected: compile failure because `TailBeatPhase` does not exist yet.

**Step 3: Implement the minimum controller**

Use an interface equivalent to:

```cpp
class TailBeatPhase
{
public:
  TailBeatPhase(double baseline_angular_frequency, double initial_time);

  void setFrequencyRatio(double ratio, double effective_time);
  double valueAt(double time) const;
  double angularFrequency() const;
  double frequencyRatio() const;
  double baselineAngularFrequency() const;

private:
  double omega0_;
  double anchor_time_;
  double anchor_phase_;
  double ratio_ = 1.0;
};
```

`setFrequencyRatio()` must first anchor the old phase at `effective_time`, then
install the new ratio. It must not update phase inside `valueAt()`.

**Step 4: Run the focused test**

Expected: PASS.

**Step 5: Commit**

```bash
git add couplings/ibamr/cases/eel2d/TailBeatPhase.h \
        couplings/ibamr/cases/eel2d/TailBeatPhase.cpp \
        couplings/ibamr/CMakeLists.txt \
        couplings/ibamr/tests/CMakeLists.txt \
        couplings/ibamr/tests/test_tail_beat_phase.cpp
git commit -m "feat: add continuous eel tail-beat phase"
```

## Task 3: Wire continuous phase into the official eel2d kinematics

**Files:**

- Modify: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.h`
- Modify: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp`
- Modify: `couplings/ibamr/cases/eel2d/upstream/input2d.in`
- Modify: `couplings/ibamr/cases/eel2d/upstream/PROVENANCE.md`
- Modify: `couplings/ibamr/scripts/render_input.cmake`
- Modify: `couplings/ibamr/tests/test_render_input.cmake`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_official_eel_formula.cpp`

**Step 1: Add failing official-equivalence tests**

For representative `s` and `t` values, compare the controlled formula at ratio
one with the original expressions:

```cpp
const double omega0 = 0.785 / 0.125;
const double envelope = 0.125 * ((s + 0.03125) / 1.03125);
const double original_shape = envelope * std::sin(2*pi*s - omega0*t);
const double controlled_shape = envelope * std::sin(2*pi*s - phase.valueAt(t));
const double original_speed = -0.785 * ((s + 0.03125) / 1.03125) *
                              std::cos(2*pi*s - omega0*t);
const double controlled_speed = -envelope * phase.angularFrequency() *
                                std::cos(2*pi*s - phase.valueAt(t));
```

Require near machine precision at ratio one. Add a CMake rendering assertion
that the generated kinematics expressions reference `PHI` and `OMEGA` and no
longer use the fixed temporal term `(0.785/0.125)*T`.

**Step 2: Run the focused tests to confirm failure**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R 'official_eel_formula|render_input' --output-on-failure
```

Expected: the render assertion fails because the input still contains the
official fixed-time expression.

**Step 3: Add the minimum kinematics interface**

Add public operations equivalent to:

```cpp
void setTailBeatFrequencyRatio(double ratio, double effective_time);
double getTailBeatFrequencyRatio() const;
double getTailBeatPhase(double time) const;
double getTailBeatAngularFrequency() const;
```

Store a `TailBeatPhase` member initialized with official `omega0 = 6.28` and the
integrator start time. Bind parser variables named `PHI` and `OMEGA` to mutable
values refreshed from the phase controller for each requested physical time.

Change only the temporal part of the input expressions:

```text
body_shape_equation = "... * sin(2*PI*X_0 - PHI)"
deformation_velocity_function_d =
  "(-0.125*OMEGA*((X_0+0.03125)/1.03125)*cos(2*PI*X_0-PHI))*N_d"
```

Do not alter the official body envelope, geometry, maneuvering logic, or normal
direction.

**Step 4: Update provenance**

Keep the official hashes as origin hashes, mark the two derived files as
locally modified, identify the design document, and state that Git diff plus
the equivalence tests define the auditable patch. Do not claim the modified
files are byte-identical to upstream.

**Step 5: Run focused and environment smoke tests**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R 'tail_beat_phase|official_eel_formula|render_input|eel_environment_smoke' \
  --output-on-failure
```

Expected: all PASS with ratio fixed at one.

**Step 6: Commit**

```bash
git add couplings/ibamr/cases/eel2d/upstream \
        couplings/ibamr/scripts/render_input.cmake \
        couplings/ibamr/tests/test_render_input.cmake \
        couplings/ibamr/tests/test_official_eel_formula.cpp \
        couplings/ibamr/CMakeLists.txt
git commit -m "feat: parameterize official eel tail-beat phase"
```

## Task 4: Add the pure target-speed task model and strict task configuration

**Files:**

- Create: `couplings/ibamr/cases/eel2d/EelControlTask.h`
- Create: `couplings/ibamr/cases/eel2d/EelControlTask.cpp`
- Create: `couplings/ibamr/configs/tasks/speed_tracking.example.conf`
- Create: `couplings/ibamr/tests/fixtures/speed_tracking_test.conf`
- Create: `couplings/ibamr/tests/test_eel_control_task.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Step 1: Define the strict configuration contract in a failing test**

Use a dependency-free `key=value` format with comments allowed only after `#`.
Required keys:

```text
baseline_angular_frequency=6.28
minimum_frequency_ratio=0.5
maximum_frequency_ratio=1.5
maximum_ratio_delta=0.1
decisions_per_baseline_period=8
target_forward_speed=<explicit value>
forward_direction_x=<explicit value>
forward_direction_y=<explicit value>
velocity_scale=<positive value>
tracking_weight=<nonnegative value>
frequency_weight=<nonnegative value>
smoothness_weight=<nonnegative value>
warmup_cycles=<nonnegative value>
episode_decisions=<positive integer>
```

The parser must reject missing, duplicate, unknown, malformed, or non-finite
values. It must reject a zero forward vector, invalid frequency bounds,
nonpositive scales, and a baseline angular frequency other than the official
6.28 unless an explicit future design changes that invariant.

The committed example must clearly mark `target_forward_speed` and forward
direction as site/run-specific values requiring baseline calibration. The
automated test fixture may use synthetic numeric values.

**Step 2: Add failing action, observation, and reward tests**

Test:

- action `-1`, `0`, and `1` map to ratios `0.5`, `1.0`, and `1.5`;
- finite actions outside the range are clipped and counted;
- NaN/infinity throws;
- slew limiting changes `1.0 -> 1.1`, not directly `1.5`;
- control interval equals `2*pi/(8*6.28)`;
- the five-state order is exactly
  `[u_bar/u_scale, u_target/u_scale, r_applied, sin(phi), cos(phi)]`;
- reward components and total match the approved equation;
- a perfect target match at ratio one with no ratio change has zero reward;
- reward inputs must be finite.

Expose types equivalent to:

```cpp
struct EelTaskConfig { /* validated fields above */ };
struct RewardBreakdown { double tracking, frequency, smoothness, total; };
struct ControlDecision { double requested_action, target_ratio, applied_ratio; };

class EelControlTask
{
public:
  explicit EelControlTask(EelTaskConfig config);
  ControlDecision applyAction(double action);
  std::array<double, 5> makeState(double forward_velocity,
                                  double phase) const;
  RewardBreakdown reward(double forward_velocity,
                         double previous_ratio) const;
  double controlInterval() const;
};
```

**Step 3: Run the test to confirm failure**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R '^eel_control_task$' --output-on-failure
```

Expected: compile failure because the task model does not exist.

**Step 4: Implement the minimum pure model and parser**

Keep this target free of Smarties, MPI, PETSc, and IBAMR so all reward and
mapping semantics can be tested deterministically.

**Step 5: Run focused tests**

Expected: `eel_control_task` and `tail_beat_phase` PASS.

**Step 6: Commit**

```bash
git add couplings/ibamr/cases/eel2d/EelControlTask.* \
        couplings/ibamr/configs/tasks \
        couplings/ibamr/tests/fixtures/speed_tracking_test.conf \
        couplings/ibamr/tests/test_eel_control_task.cpp \
        couplings/ibamr/CMakeLists.txt \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: define eel target-speed control task"
```

## Task 5: Let `EelEnvironment` own frequency application and control intervals

**Files:**

- Modify: `couplings/ibamr/cases/eel2d/EelEnvironment.h`
- Modify: `couplings/ibamr/cases/eel2d/EelEnvironment.cpp`
- Create: `couplings/ibamr/tests/test_eel_environment_control.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Step 1: Write the failing real-environment test**

Define an environment result type equivalent to:

```cpp
struct ControlIntervalResult
{
  double start_time;
  double end_time;
  std::array<double, 2> start_com;
  std::array<double, 2> end_com;
  unsigned ibamr_steps;
};
```

The test must initialize the coarse real eel, then verify:

- current time, COM, phase, and ratio are finite;
- applying ratio one at current time is continuous;
- applying `0.9` changes the reported ratio but not phase at the switch;
- `advanceControlInterval(nominal_duration)` advances at least one native
  IBAMR step and returns actual elapsed time;
- returned COM values are finite;
- `advanceOneStep()` remains available for the stage-one regression;
- shutdown leaves MPI active for `MpiSession`/`CouplingDriver` to own.

**Step 2: Run to confirm compile failure**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R '^eel_environment_control$' --output-on-failure
```

**Step 3: Implement the environment API**

Add operations equivalent to:

```cpp
void setTailBeatFrequencyRatio(double ratio);
ControlIntervalResult advanceControlInterval(double nominal_duration);
double currentTime() const;
std::array<double, 2> currentCenterOfMass() const;
double currentTailBeatPhase() const;
double currentTailBeatFrequencyRatio() const;
```

Keep a typed `Pointer<IBEELKinematics>` in `Impl` in addition to the base-class
registration pointer. Apply commands only before beginning an IBAMR advance.
`advanceControlInterval()` must loop through existing `advanceOneStep()` calls
until current time reaches/crosses the nominal end or IBAMR has no steps
remaining. It must compute nothing using assumed `dt`; return the actual times
and step count.

Do not move MPI, PETSc, SAMRAI, or IBTK initialization. Preserve
`PETSC_COMM_WORLD = environment_comm` before `IBTKInit` and the SAMRAI
communicator restoration.

**Step 4: Run real environment regressions**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R 'eel_environment_(smoke|control)' --output-on-failure
```

Expected: both PASS.

**Step 5: Commit**

```bash
git add couplings/ibamr/cases/eel2d/EelEnvironment.* \
        couplings/ibamr/tests/test_eel_environment_control.cpp \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: advance eel by controlled frequency intervals"
```

## Task 6: Add the multi-decision Smarties speed-tracking protocol

**Files:**

- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.h`
- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`
- Modify: `couplings/ibamr/cases/eel2d/main.cpp`
- Create: `couplings/ibamr/tests/test_eel_control_protocol.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Step 1: Preserve the old smoke callback**

Keep `runSmokeEpisode()` and its one-state/one-action lifecycle semantics so
stage-one ownership tests continue to run unchanged. Add a separate callback:

```cpp
void runSpeedTrackingEpisode(smarties::Communicator* comm,
                             MPI_Comm environment_comm,
                             int argc,
                             char** argv);
```

Do not turn the lifecycle smoke test into a training test.

**Step 2: Write the failing controlled-protocol test**

Add a report with at least:

```cpp
struct ControlProtocolReport
{
  unsigned completed_decisions;
  unsigned completed_ibamr_steps;
  unsigned clipped_actions;
  bool terminal_sent;
  bool finite_state_and_reward;
};
```

The MPI integration test must require:

- one learner rank plus one environment rank;
- state dimension five and action dimension one;
- more than one completed decision;
- at least as many IBAMR steps as decisions;
- one environment terminal transition;
- finite state/reward values;
- MPI remains active when `CouplingDriver::run()` returns;
- MPI is finalized only when `CouplingDriver` is destroyed.

Run it first and expect compile failure because the callback/report do not yet
exist.

**Step 3: Implement warmup and initial-state exchange**

Parse only `--task-file` and `--eel-mode` adapter options; the task file owns
the remaining parameters. Initialize the real environment, run configured
warmup intervals at ratio one without Smarties actions, compute the first
finite state, then call `sendInitState(state)`.

Warmup must not create a second environment or touch the MPI lifecycle.

**Step 4: Implement one controlled transition**

For each decision:

1. receive one Smarties action;
2. validate/map/clip/slew it through `EelControlTask`;
3. apply the ratio at `environment.currentTime()`;
4. advance one nominal control interval inside `EelEnvironment`;
5. calculate interval-averaged forward COM velocity using actual elapsed time;
6. form the five-state observation;
7. calculate and log each reward component;
8. send normal or terminal state; and
9. check Smarties termination without starting another IBAMR episode.

Emit one parseable line per decision, only from environment rank zero:

```text
EEL_CONTROL decision=N action=... target_ratio=... applied_ratio=... \
start_time=... end_time=... ibamr_steps=... forward_velocity=... \
reward_tracking=... reward_frequency=... reward_smoothness=... reward_total=...
```

Emit one terminal summary:

```text
EEL_CONTROL_TERMINAL decisions=... ibamr_steps=... clipped_actions=... reason=...
```

**Step 5: Keep fatal error ownership unchanged**

All exceptions after environment initialization must continue through the
existing environment-communicator `MPI_Abort` path. Do not add private
`MPI_Finalize`, new communicator frees, or process spawning.

**Step 6: Select the callback in `main.cpp`**

Read `--eel-mode smoke|speed-tracking` before constructing the driver, then
pass the selected callback to the same `CouplingDriver`. Default to `smoke` for
backward compatibility. Reject unknown mode before distributed framework
initialization.

**Step 7: Run protocol and ownership tests**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R 'eel_(smoke|control)_protocol|borrowed_.*shutdown|mpi_session' \
  --output-on-failure
```

Expected: all PASS.

**Step 8: Commit**

```bash
git add couplings/ibamr/cases/eel2d/EelSmartiesAdapter.* \
        couplings/ibamr/cases/eel2d/main.cpp \
        couplings/ibamr/tests/test_eel_control_protocol.cpp \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: couple Smarties to eel frequency control"
```

## Task 7: Add a deterministic physical frequency-response probe

**Files:**

- Create: `couplings/ibamr/cases/eel2d/frequency_response_probe.cpp`
- Create: `couplings/ibamr/tests/test_frequency_response_probe.cmake`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Step 1: Write a failing probe integration test**

The probe runs the same official real environment without Smarties, sequentially
from fresh MPI jobs at ratios `0.5`, `1.0`, and `1.5`. Each run prints:

```text
EEL_FREQUENCY_PROBE ratio=... decisions=... ibamr_steps=... \
elapsed_time=... forward_displacement=... mean_forward_velocity=... \
phase_start=... phase_end=...
```

The CMake test must validate finite results, positive elapsed time, and phase
advance consistent with `omega0 * ratio * elapsed_time`. It must not assert a
monotonic COM response until node3 data verifies that physical relationship.

**Step 2: Implement the probe using `MpiSession` and `EelEnvironment`**

The probe is diagnostic only. It must use the same environment code and must
not copy the solver loop. It must leave MPI finalization to `MpiSession`.

**Step 3: Run the probe test**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R 'frequency_response_probe' --output-on-failure
```

Expected: PASS for each configured ratio.

**Step 4: Commit**

```bash
git add couplings/ibamr/cases/eel2d/frequency_response_probe.cpp \
        couplings/ibamr/tests/test_frequency_response_probe.cmake \
        couplings/ibamr/CMakeLists.txt \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "test: add real eel frequency response probe"
```

## Task 8: Enable the simple `train` launcher and complete run manifests

**Files:**

- Modify: `couplings/ibamr/scripts/run_node3.sh`
- Modify: `couplings/ibamr/scripts/build_node3.sh`
- Create: `couplings/ibamr/configs/training/speed_tracking.json`
- Modify: `couplings/ibamr/tests/test_node3_scripts.sh`
- Modify: `couplings/ibamr/README.md`

**Step 1: Add failing launcher tests**

Replace the old assertion that `train` always exits 64 with tests requiring:

- `train --dry-run` accepts a valid `--task` file;
- missing task file fails before MPI launch;
- malformed task config fails before MPI launch where shell validation is
  possible, and always before IBAMR initialization;
- total ranks remain `learner_ranks + envs * ranks_per_env`;
- train command contains `--eel-mode speed-tracking`, `--task-file task.conf`,
  and a positive Smarties `--nTrainSteps`;
- smoke still contains `--eel-mode smoke` and its existing options;
- real-run fixture copies `task.conf` and records its SHA-256;
- stale/tampered executable rebuilding continues to work;
- fidelity curriculum argument separation remains comma-based.

Run:

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
```

Expected: FAIL because train mode is still disabled.

**Step 2: Implement the train CLI**

Support a simple command of the form:

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --envs 1 \
  --ranks-per-env 1 \
  --fidelity coarse \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task /absolute/or/repository/relative/task.conf \
  --train-steps 64
```

Keep `smoke` unchanged. Train mode is labelled
`stage2_physical_control_experimental` in stdout and the manifest until full
admission; this label describes evidence status, not MPI ownership.

**Step 3: Extend build and run identity**

Record and verify the same executable path/hash used by both modes. Add to the
run manifest:

```text
eel_mode=
task_file=
task_sha256=
train_steps=
state_dimension=5
action_dimension=1
control_stage=stage2_physical_control_experimental
```

The task file copied into the run directory is the one passed to the adapter.
Do not rely on a mutable source path after the manifest is written.

**Step 4: Add conservative Smarties CPU settings**

Create `speed_tracking.json` with the native Smarties learner only. Do not add
PyTorch/CUDA keys. Keep sizes intentionally small for the node3 admission run;
policy-quality tuning is deferred.

**Step 5: Run script tests**

Expected: PASS.

**Step 6: Commit**

```bash
git add couplings/ibamr/scripts/run_node3.sh \
        couplings/ibamr/scripts/build_node3.sh \
        couplings/ibamr/configs/training/speed_tracking.json \
        couplings/ibamr/tests/test_node3_scripts.sh \
        couplings/ibamr/README.md
git commit -m "feat: launch eel speed-tracking training"
```

## Task 9: Calibrate forward direction and create the node3 admission task

**Files:**

- Create only after measurement:
  `couplings/ibamr/configs/tasks/speed_tracking_node3_coarse.conf`
- Store raw, uncommitted evidence first under:
  `.artifacts/stage2/calibration/`
- Modify if needed: `couplings/ibamr/README.md`

**Step 1: Package the exact local revision**

```powershell
.\couplings\ibamr\scripts\package_local.ps1 `
  -Repository . `
  -OutputDirectory .artifacts\packages
```

Verify the archive SHA and source manifest locally before upload.

**Step 2: Upload and build on node3**

Use immutable directories:

```bash
./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/<revision> \
  --build /data2/mjwu/local/coupling-build/<revision>
```

The script must source
`/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh` and confirm GCC/G++
8.5.0 before CMake.

**Step 3: Run the deterministic ratio-one probe**

Run enough baseline intervals to move beyond immediate initialization noise.
Record the global x/y COM displacement and mean velocity in
`.artifacts/stage2/calibration/`. Determine the forward unit direction from the
official fish's measured baseline motion; do not infer it from the equation
alone.

**Step 4: Select a conservative explicit target**

For admission, choose a target within the stable baseline range, document the
measured interval and selection rule, and create
`speed_tracking_node3_coarse.conf`. Do not claim the target is optimal.

**Step 5: Repackage after adding the calibrated config**

Because the config is part of the run identity, commit it and create a new
package/revision before the final admission matrix.

```bash
git add couplings/ibamr/configs/tasks/speed_tracking_node3_coarse.conf \
        couplings/ibamr/README.md
git commit -m "config: add calibrated node3 eel tracking task"
```

## Task 10: Run complete local and node3 verification for one clean revision

**Files:**

- Write raw results only under: `.artifacts/stage2/admission/<revision>/`
- Do not create verified experience yet.

**Step 1: Run all local/static tests**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
bash couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh
cmake -DCOUPLING_ROOT="$PWD/couplings/ibamr" \
  -P couplings/ibamr/tests/test_render_input.cmake
```

Expected: PASS.

**Step 2: Build the exact final revision on node3**

Confirm the source revision, build revision, executable SHA, IBAMR version,
PETSc version, compiler, MPI wrapper, and SAMRAI patch hash all match the run
manifest.

**Step 3: Run the complete CTest suite**

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<revision> \
  --output-on-failure
```

Expected: 100% PASS, including new pure, real-environment, protocol, and probe
tests.

**Step 4: Repeat the physical response probe**

Run fresh MPI jobs for ratios `0.5`, `1.0`, and `1.5`, at least three times
each. Verify:

- requested and applied ratios match the diagnostic command;
- phase advance matches actual time and applied ratio;
- COM trajectories are finite and reproducible within documented numerical
  tolerance; and
- any claimed action/trajectory relationship is supported by the measurements.

**Step 5: Run the train topology matrix**

For each supported topology, run at least three repetitions:

```text
envs=1 ranks_per_env=1
envs=1 ranks_per_env=2
envs=2 ranks_per_env=1
envs=2 ranks_per_env=2
```

Use the calibrated coarse task and a bounded multi-decision horizon. For each
run require:

- exit code zero;
- exactly one terminal summary per environment;
- more than one decision per environment;
- finite state and reward components;
- real IBAMR steps greater than or equal to decisions;
- no private MPI finalization message;
- revision/config/executable hashes match.

**Step 6: Run failure injection**

Repeat `--fault-after-initialize` with at least two environment ranks. Require
the expected nonzero abort code, the coordinated fatal log, and an immediate
process snapshot showing no residual MPI/eel processes.

**Step 7: Run clean-shutdown process snapshots**

Capture process snapshots immediately after representative successful runs and
after the injected failure. Store commands and outputs, not only conclusions.

**Step 8: Independently inspect evidence**

Use `superpowers:requesting-code-review` and a separate evidence review before
admission. Any unresolved Critical or Important issue blocks promotion.

## Task 11: Admit verified experience, integrate, and push

**Files:**

- Create only if every gate passes:
  `experience/verified/2026-08-XX-eel2d-frequency-control-stage2.md`
- Modify: `couplings/ibamr/README.md`

**Step 1: Write only verified conclusions**

The experience note must include:

- exact Git revision and executable SHA;
- node3 compiler/MPI/IBAMR/PETSc/SAMRAI identities;
- task config hash and action/state/reward contract;
- phase-equivalence and continuity evidence;
- physical-response measurements without overclaiming monotonicity;
- topology repetitions;
- failure and process-cleanup evidence;
- known limitations: one physical episode, no reset, no energy claim, no GPU,
  and no policy-quality claim.

If any item is uncertain, leave it in `.artifacts` and omit it from verified
experience.

**Step 2: Run final verification before the documentation commit**

```bash
git diff --check
ctest --test-dir /data2/mjwu/local/coupling-build/<revision> \
  --output-on-failure
```

Expected: clean diff check and 100% tests passed for the same revision whose
evidence is cited. If adding only documentation changes the revision, record
both the tested code revision and the documentation revision explicitly; do not
pretend the executable hash changed.

**Step 3: Commit verified experience**

```bash
git add experience/verified/2026-08-XX-eel2d-frequency-control-stage2.md \
        couplings/ibamr/README.md
git commit -m "docs: admit verified eel frequency control"
```

**Step 4: Review and integrate**

Use `superpowers:finishing-a-development-branch` after all tests pass. Merge
`feature/eel2d-frequency-control` into `feature/ibamr-eel2d-coupling` without
including unrelated files. Re-run `git status`, `git log`, and the lightweight
script tests after merge.

**Step 5: Push the requested GitHub branch**

```bash
git push origin feature/ibamr-eel2d-coupling
```

Expected remote:

```text
https://github.com/echoWuMJ/smarties/tree/feature/ibamr-eel2d-coupling
```

Report the final branch revision, tested code revision, node3 evidence path,
and remaining deferred stages to the user.
