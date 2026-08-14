# Smarties CPU Learner Consistency and Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the existing Smarties native CPU learner for precision selection, deterministic updates, threaded numerical consistency, checkpoint recovery, synthetic VRACER convergence, and one real medium-eel network update.

**Architecture:** Keep the long-lived driver-owned MPI topology. Add opt-in, read-only learner audit instrumentation to the native Smarties network; validate it first with a direct Adam probe, then with a deterministic synthetic environment through the production VRACER path, and finally with one short two-rank IBAMR eel episode. PyTorch and CUDA remain completely untouched.

**Tech Stack:** C++14, Smarties native `Network`/`AdamOptimizer`/VRACER, OpenMP, MPI/Open MPI, CMake/CTest, Bash/PowerShell packaging, IBAMR 0.18.0, PETSc 3.23.3.

## Global Constraints

- `CouplingDriver` is the sole owner of `MPI_Init_thread()` and `MPI_Finalize()` for coupled runs.
- Smarties borrows the supplied communicator, frees only owned duplicates, and never finalizes borrowed MPI.
- Keep `--learnersOnWorkers 0`; learner ranks and environment ranks remain separate.
- No process forks after MPI initialization.
- Only eel environment ranks initialize PETSc, SAMRAI, IBTK, and IBAMR; synthetic ranks never do.
- IBAMR owns the CFD loop and exchanges data only at the existing control boundary.
- Normal destruction is inside-out and the driver finalizes MPI last; fatal distributed failures use `MPI_Abort`.
- Do not add, enable, repair, compile, or test PyTorch, CUDA, pybind11, or Python bindings.
- Target learner builds use `SINGLE_PRECISION=ON`, `COMPILE_PY_SO=OFF`, and must prove `sizeof(nnReal)==4`.
- One-thread/four-thread one-update comparison uses frozen `atol=1e-6`, `rtol=1e-5`.
- Synthetic seeds are exactly 11, 29, and 47; each target run performs exactly 1024 optimizer updates.
- Same-thread repeats require identical parameter digests; long cross-thread runs compare policy quality, not byte-identical weights.
- Target runs use explicit core binding, four OpenMP threads per MPI rank, and reject oversubscription.
- A slow but advancing run is not an algorithm failure; an external interruption is `OPERATIONAL_INCOMPLETE`.
- Do not widen tolerances, replace seeds, or rerun an admitted target merely because it failed.
- Keep hypotheses and incomplete evidence under `.artifacts/ibamr-smarties-investigations/`; promote nothing to `experience/verified/` without the coupling skill's full closure gate.

---

### Task 1: Repair and prove the native-network precision option

**Files:**
- Modify: `CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_network_precision.cpp`
- Create: `couplings/ibamr/tests/test_network_precision_contract.cmake`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `smarties_network_precision_probe`, which prints exactly `SMARTIES_NETWORK_PRECISION bytes=<N> single_macro=<0|1>`.
- Produces: CMake contract where `SINGLE_PRECISION`, not `COMPILE_PY_SO`, controls the public `SINGLE_PREC` definition.
- Consumed by: every later task and every node3 evidence manifest.

- [ ] **Step 1: Write the CMake contract RED fixture**

Create `test_network_precision_contract.cmake` to read the repository root
`CMakeLists.txt`, locate the compile-definition block, and fail unless it is
guarded by `if(SINGLE_PRECISION)` and outside `if(COMPILE_PY_SO)`:

```cmake
if(NOT DEFINED ROOT_CMAKE OR NOT EXISTS "${ROOT_CMAKE}")
  message(FATAL_ERROR "precision contract requires ROOT_CMAKE")
endif()
file(READ "${ROOT_CMAKE}" source)
string(REGEX MATCH
  "if *\\(SINGLE_PRECISION\\)[\r\n ]+target_compile_definitions *\\([^\n]+SINGLE_PREC"
  precision_block "${source}")
if(precision_block STREQUAL "")
  message(FATAL_ERROR "SINGLE_PRECISION does not control SINGLE_PREC")
endif()
string(REGEX MATCH
  "if *\\(COMPILE_PY_SO\\)[^#]*target_compile_(options|definitions) *\\([^\n]+SINGLE_PREC"
  python_coupled_block "${source}")
if(NOT python_coupled_block STREQUAL "")
  message(FATAL_ERROR "network precision still depends on COMPILE_PY_SO")
endif()
```

- [ ] **Step 2: Run the RED fixture**

Run:

```powershell
cmake "-DROOT_CMAKE=$PWD/CMakeLists.txt" -P couplings/ibamr/tests/test_network_precision_contract.cmake
```

Expected: exit nonzero with `SINGLE_PRECISION does not control SINGLE_PREC`.

- [ ] **Step 3: Write the compiled precision probe**

Create `test_network_precision.cpp`:

```cpp
#include "smarties/Settings/Definitions.h"
#include <cstdio>

#ifndef SMARTIES_EXPECT_NNREAL_BYTES
#error SMARTIES_EXPECT_NNREAL_BYTES must be defined
#endif

int main()
{
  const int bytes = static_cast<int>(sizeof(smarties::nnReal));
#ifdef SINGLE_PREC
  const int single_macro = 1;
#else
  const int single_macro = 0;
#endif
  std::printf("SMARTIES_NETWORK_PRECISION bytes=%d single_macro=%d\n",
              bytes, single_macro);
  return bytes == SMARTIES_EXPECT_NNREAL_BYTES ? 0 : 1;
}
```

- [ ] **Step 4: Implement the minimal CMake fix and register the probe**

Replace the incorrect Python-binding guard with:

```cmake
if(SINGLE_PRECISION)
  target_compile_definitions(${smarties_core} PUBLIC SINGLE_PREC)
  set(SMARTIES_EXPECT_NNREAL_BYTES 4)
else()
  set(SMARTIES_EXPECT_NNREAL_BYTES 8)
endif()
```

Keep the later `if(COMPILE_PY_SO)` block responsible only for pybind11. Register
the probe with the expected byte count:

```cmake
add_executable(smarties_network_precision_probe test_network_precision.cpp)
target_include_directories(smarties_network_precision_probe PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_compile_definitions(smarties_network_precision_probe PRIVATE
  SMARTIES_EXPECT_NNREAL_BYTES=${SMARTIES_EXPECT_NNREAL_BYTES})
target_link_libraries(smarties_network_precision_probe PRIVATE libsmarties)
add_test(NAME smarties_network_precision
  COMMAND smarties_network_precision_probe)
```

- [ ] **Step 5: Verify both precision configurations**

On a compiler-equipped environment, configure two fresh trees with
`COMPILE_PY_SO=OFF`:

```bash
cmake -S . -B build-precision-f32 -DCOMPILE_PY_SO=OFF -DSINGLE_PRECISION=ON -DBUILD_IBAMR_COUPLING_TESTS=ON
cmake --build build-precision-f32 --target smarties_network_precision_probe -j2
ctest --test-dir build-precision-f32 -R '^smarties_network_precision$' --output-on-failure
cmake -S . -B build-precision-f64 -DCOMPILE_PY_SO=OFF -DSINGLE_PRECISION=OFF -DBUILD_IBAMR_COUPLING_TESTS=ON
cmake --build build-precision-f64 --target smarties_network_precision_probe -j2
ctest --test-dir build-precision-f64 -R '^smarties_network_precision$' --output-on-failure
```

Expected: float build prints `bytes=4 single_macro=1`; double build prints
`bytes=8 single_macro=0`.

- [ ] **Step 6: Commit Task 1**

```bash
git add CMakeLists.txt couplings/ibamr/tests/test_network_precision.cpp couplings/ibamr/tests/test_network_precision_contract.cmake couplings/ibamr/tests/CMakeLists.txt
git commit -m "fix: decouple network precision from Python bindings"
```

---

### Task 2: Add stable, opt-in parameter audit primitives

**Files:**
- Create: `source/smarties/Network/NetworkAudit.h`
- Create: `source/smarties/Network/NetworkAudit.cpp`
- Modify: `CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_network_audit.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `smarties::ParameterAudit auditParameters(const Parameters&)`.
- Produces: `formatParameterAudit(stage, network, optimizer_step, threads, audit)` canonical key/value output.
- `ParameterAudit` fields: `count`, `digest`, `sum`, `sum_squares`, `max_abs`, `finite`, and `precision_bytes`.
- Consumed by: native update probe and production learner audit hook.

- [ ] **Step 1: Write RED tests for digest, mutation, and non-finite data**

Create a test that allocates a `Parameters` object with four known `nnReal`
values, verifies a stable digest, changes one bit and verifies the digest
changes, then injects positive infinity and requires `finite=false`. Do not use
`std::isfinite` as the only check because `libsmarties` is compiled with
`-ffast-math` in Release.

```cpp
const auto first = smarties::auditParameters(*params);
if (!first.finite || first.count != 4) return 1;
params->params[2] = std::nextafter(params->params[2], nnReal(9));
const auto changed = smarties::auditParameters(*params);
if (changed.digest == first.digest) return 2;
params->params[1] = std::numeric_limits<nnReal>::infinity();
if (smarties::auditParameters(*params).finite) return 3;
```

- [ ] **Step 2: Run the RED build**

Build `network_audit_test`. Expected: compilation fails because
`NetworkAudit.h` and `auditParameters` do not exist.

- [ ] **Step 3: Implement the audit primitive**

Use FNV-1a over the raw `nnReal` bytes for a stable same-architecture digest.
Detect finite values by inspecting IEEE exponent bits with `memcpy`, not by
allowing fast-math to optimize away the check. Accumulate numeric summaries in
`long double`. Format one line with fixed field order:

```text
SMARTIES_NETWORK_AUDIT stage=<stage> network=<name> step=<N> threads=<N> precision_bytes=<N> params=<N> digest=<16-hex> sum=<value> sum_squares=<value> max_abs=<value> finite=<0|1>
```

Reject stage or network labels containing whitespace so the record remains
unambiguous.

- [ ] **Step 4: Register and run the focused GREEN test**

Register `network_audit_test` as `smarties_network_audit`. Run it in both
precision build trees from Task 1. Expected: both pass and report their actual
precision byte count.

- [ ] **Step 5: Commit Task 2**

```bash
git add CMakeLists.txt source/smarties/Network/NetworkAudit.h source/smarties/Network/NetworkAudit.cpp couplings/ibamr/tests/test_network_audit.cpp couplings/ibamr/tests/CMakeLists.txt
git commit -m "test: add native network audit primitives"
```

---

### Task 3: Build the deterministic Adam update and checkpoint probe

**Files:**
- Create: `couplings/ibamr/tests/network_update_probe.cpp`
- Create: `couplings/ibamr/tests/NetworkAuditCompare.cmake`
- Create: `couplings/ibamr/tests/test_network_update_consistency.cmake`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Modify: `source/smarties/Network/Optimizer.h`
- Modify: `source/smarties/Network/Optimizer.cpp`
- Modify: `source/smarties/Network/Approximator.h`

**Interfaces:**
- Produces executable: `smarties_network_update_probe --threads <1|4> --updates <N> --seed <N> --audit-file <path> [--checkpoint-dir <path>] [--restart-dir <path>]`.
- Produces comparator result: `PASS`, `DETERMINISM_MISMATCH`, `THREADED_UPDATE_MISMATCH`, `NONFINITE_UPDATE`, `CHECKPOINT_MISMATCH`, or `NO_FIXED_DATA_CONVERGENCE`.
- Produces optimizer method: `virtual void setStep(Uint step)`; Adam override restores `nStep` and bias-correction powers consistently.
- Consumed by: production checkpoint recovery and node3 focused gate.

- [ ] **Step 1: Write the probe fixture and orchestration RED**

The probe must construct `ExecutionInfo` on one borrowed MPI communicator,
freeze seed 11, build a 5-16-16-1 `Tanh/Tanh/Linear` network, and create exactly
64 deterministic samples. The target is:

```cpp
const nnReal target = std::max(nnReal(-0.8), std::min(nnReal(0.8),
  nnReal(0.60)*state[0] - nnReal(0.25)*state[1] + nnReal(0.15)*state[2]));
```

Partition samples using a static OpenMP schedule. Each thread writes only its
own `Builder::threadGrads[thread_id]`. Call `prepare_update({})`, wait for
`ready2UpdateWeights()`, then call `apply_update()`.

The CMake orchestrator must run:

- seed 11, one thread, one update, twice;
- seed 11, four threads, one update;
- seed 11, one thread, 200 updates;
- seven updates plus checkpoint, then one resumed update;
- eight uninterrupted updates for the checkpoint control.

Expected initial RED: missing executable/comparator.

- [ ] **Step 2: Implement the minimum probe without checkpoint-step repair**

Emit audit lines at initialization, after update 1, after update 200, and after
reload. Also emit:

```text
SMARTIES_NETWORK_LOSS step=<N> mean_squared_error=<value> finite=<0|1>
```

Save weights and Adam moments through the existing `Optimizer::save` callback.
Restart through `Optimizer::restart` and call the existing
`Approximator::setNgradSteps` path.

- [ ] **Step 3: Run the checkpoint continuation RED**

Expected: immediate weights reload, but the next resumed Adam update diverges
from uninterrupted update 8 because the existing setter restores only `nStep`
and not `beta_t_1`/`beta_t_2`.

- [ ] **Step 4: Repair Adam step restoration**

Add the interface:

```cpp
virtual void setStep(const Uint step) { nStep = step; }
```

Override it in `AdamOptimizer`:

```cpp
void AdamOptimizer::setStep(const Uint step)
{
  nStep = step;
  beta_t_1 = std::pow(beta_1, static_cast<Real>(step + 1));
  beta_t_2 = std::pow(beta_2, static_cast<Real>(step + 1));
  if (beta_t_1 < nnEPS) beta_t_1 = 0;
  if (beta_t_2 < nnEPS) beta_t_2 = 0;
}
```

Change `Approximator::setNgradSteps` to call `opt->setStep(iter)` rather than
assigning `opt->nStep` directly. Keep old checkpoint file names and make no
format-breaking change.

- [ ] **Step 5: Implement the frozen comparator**

`NetworkAuditCompare.cmake` must require:

- identical initial digest for all comparable runs;
- identical same-thread repeat digests and loss records;
- every `finite=1`;
- one-thread/four-thread one-update parameters and fixed predictions within
  `atol=1e-6`, `rtol=1e-5`;
- update count exactly as requested;
- last-20 mean loss at 200 updates no more than 25 percent of first-20 mean;
- resumed update 8 digest and predictions equal to uninterrupted update 8.

The comparator must print the first failed field, both values, absolute
difference, and tolerance.

- [ ] **Step 6: Run focused GREEN tests in float32 and diagnostic double builds**

Run `smarties_network_update_consistency` in both precision trees. The float32
result is the target gate. The double result is diagnostic and must pass its
own same-thread/checkpoint checks; it is not substituted for float32 evidence.

- [ ] **Step 7: Commit Task 3**

```bash
git add source/smarties/Network/Optimizer.h source/smarties/Network/Optimizer.cpp source/smarties/Network/Approximator.h couplings/ibamr/tests/network_update_probe.cpp couplings/ibamr/tests/NetworkAuditCompare.cmake couplings/ibamr/tests/test_network_update_consistency.cmake couplings/ibamr/tests/CMakeLists.txt
git commit -m "test: verify threaded Adam updates and restart"
```

---

### Task 4: Add opt-in production learner audit and checkpoint hooks

**Files:**
- Modify: `source/smarties/Settings/ExecutionInfo.h`
- Modify: `source/smarties/Settings/ExecutionInfo.cpp`
- Modify: `source/smarties/Learners/Learner.h`
- Modify: `source/smarties/Learners/Learner.cpp`
- Modify: `source/smarties/Learners/Learner_approximator.h`
- Modify: `source/smarties/Learners/Learner_approximator.cpp`
- Modify: `source/smarties/Core/Worker.cpp`
- Create: `couplings/ibamr/tests/test_learner_audit_options.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces CLI option: `--learnerAuditDir <absolute-path>`, default `none`.
- Produces audit stages: `initialized`, `update`, `final`, and `restart`.
- Produces checkpoint directories: `<audit-dir>/initial` and `<audit-dir>/final`.
- Disabled mode performs no audit I/O and does not alter update order.

- [ ] **Step 1: Write option and disabled-mode RED tests**

Test that `ExecutionInfo::parse()` accepts an absolute audit directory, rejects
an empty relative path, and defaults to `none`. A source-level fixture must
also fail unless the disabled path returns before creating directories or
calling `auditParameters`.

- [ ] **Step 2: Add the CLI option with validation**

Add:

```cpp
std::string learnerAuditDir = "none";
```

and register:

```cpp
parser.add_option("--learnerAuditDir", learnerAuditDir,
  "Absolute directory for opt-in native learner audit and checkpoints.");
```

Resolve the path before Smarties changes run directories. Reject non-absolute
values except `none`.

- [ ] **Step 3: Add lifecycle hooks without algorithm changes**

Add protected virtual no-op hooks `onTrainingInitialized()` and
`onTrainingFinalized()` to `Learner`. Call the first once at the end of
successful `initializeLearner()`. After the existing training loop has ended
and its data-coordinator thread has joined, make `Worker::runTraining()` call
the second hook exactly once on each local learner before learner destruction.
Override both hooks in `Learner_approximator`: the initial hook emits
`initialized` records and saves a complete network-plus-memory checkpoint under
`<audit-dir>/initial`; the final hook verifies the optimizer's actual step,
emits `final`, and saves the equivalent checkpoint under `<audit-dir>/final`.

After every existing `net->applyUpdate()` call in `applyGradient()`, emit one
`update` record using the optimizer's actual step number. Do not insert a new
barrier, change replay sampling, or reorder the update loop.

Do not infer the final audit checkpoint from the existing `saveFreq` boundary:
that boundary uses `nGradSteps()+1` and is not an exact end-of-training signal.
Leave normal `save()` behavior unchanged. At the end of the existing
`restart()` load, emit `restart`. Only learner communicator rank zero writes
records and creates directories.

- [ ] **Step 4: Make checkpoint paths explicit and backward compatible**

Add a private helper that calls existing network and memory-buffer save
functions with an absolute base such as:

```cpp
const std::string base = audit_dir + "/" + stage + "/" + learner_name;
for (const auto& net : networks) net->save(base, false);
data->save(base);
```

Do not rename or remove normal Smarties checkpoint files. Audit checkpoints are
additional opt-in artifacts.

- [ ] **Step 5: Run focused lifecycle and borrowed-MPI regression tests**

Run:

```bash
ctest --test-dir BUILD -R '^(learner_audit_options|borrowed_engine_shutdown|borrowed_communicator_alias|curriculum_arguments)$' --output-on-failure
```

Expected: audit option tests pass, disabled mode creates nothing, and borrowed
MPI ownership remains unchanged.

- [ ] **Step 6: Commit Task 4**

```bash
git add source/smarties/Settings/ExecutionInfo.h source/smarties/Settings/ExecutionInfo.cpp source/smarties/Learners/Learner.h source/smarties/Learners/Learner.cpp source/smarties/Learners/Learner_approximator.h source/smarties/Learners/Learner_approximator.cpp source/smarties/Core/Worker.cpp couplings/ibamr/tests/test_learner_audit_options.cpp couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: add opt-in native learner audit"
```

---

### Task 5: Add the deterministic production-VRACER synthetic environment

**Files:**
- Create: `couplings/ibamr/cases/synthetic/CpuLearnerEnvironment.h`
- Create: `couplings/ibamr/cases/synthetic/CpuLearnerEnvironment.cpp`
- Create: `couplings/ibamr/cases/synthetic/main.cpp`
- Create: `couplings/ibamr/configs/training/cpu_learner_convergence.json`
- Create: `couplings/ibamr/tests/test_cpu_learner_environment.cpp`
- Create: `couplings/ibamr/tests/fixtures/cpu_learner_smoke.json`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces executable: `smarties_cpu_learner_environment` using `CouplingDriver`.
- State dimension: 5; bounded action dimension: 1 in `[-1,1]`.
- Episode length: 32; target action: `clip(0.60*s0 - 0.25*s1 + 0.15*s2, -0.80, 0.80)`.
- Canonical outputs: `SMARTIES_SYNTHETIC_STEP`, `SMARTIES_SYNTHETIC_EPISODE`, and `SMARTIES_SYNTHETIC_SUMMARY`.

- [ ] **Step 1: Write pure environment RED tests**

Test exact state generation for seeds 11, 29, and 47; bounds for 256 states;
target-action calculation; reward equality to negative squared error; 32-step
terminal behavior; and reset producing the next deterministic episode.

- [ ] **Step 2: Implement the pure environment model**

Use an explicitly coded SplitMix64 generator keyed by seed, environment ID,
episode, decision, and state component. Convert the high 53 bits to a double
in `[0,1)` and then to `[-1,1]`. Do not use `std::random_device`, wall time, or
thread ID.

- [ ] **Step 3: Implement the Smarties callback**

The callback must:

```cpp
comm->setStateActionDims(5, 1);
comm->setActionScales({1.0}, {-1.0}, true);
while (!comm->terminateTraining()) {
  environment.reset();
  comm->sendInitState(environment.state());
  for (unsigned step = 0; step < 32; ++step) {
    const auto action = comm->recvAction();
    if (comm->terminateTraining()) return;
    const auto transition = environment.advance(action.at(0));
    if (transition.terminal)
      comm->sendTermState(transition.state, transition.reward);
    else
      comm->sendState(transition.state, transition.reward);
  }
}
```

Use the supplied environment communicator only for environment identity and
coordinated failure. Do not initialize any CFD library. `main.cpp` constructs
`CouplingDriver` and passes this callback.

- [ ] **Step 4: Add frozen training settings**

Commit:

```json
{
  "learner": "VRACER",
  "batchSize": 8,
  "encoderLayerSizes": [0],
  "maxTotObsNum": 4096,
  "minTotObsNum": 64,
  "nnLayerSizes": [16, 16],
  "obsPerStep": 1,
  "saveFreq": 1000000
}
```

The large `saveFreq` deliberately keeps the normal Smarties checkpoint cadence
out of this validation. Exact initial/final checkpoints come from the explicit
audit lifecycle hooks. The smoke fixture uses the same topology with
`maxTotObsNum=64`, `minTotObsNum=8`, and the same audit-finalization path.

- [ ] **Step 5: Register a fast protocol test**

Run one learner rank plus one synthetic worker, one thread, and two updates.
Require two audit update records, terminal episodes, final checkpoint, clean
return through `CouplingDriver`, and no private `MPI_Finalize`.

- [ ] **Step 6: Commit Task 5**

```bash
git add couplings/ibamr/cases/synthetic couplings/ibamr/configs/training/cpu_learner_convergence.json couplings/ibamr/tests/test_cpu_learner_environment.cpp couplings/ibamr/tests/fixtures/cpu_learner_smoke.json couplings/ibamr/CMakeLists.txt couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: add deterministic CPU learner environment"
```

---

### Task 6: Add the frozen one-thread/four-thread convergence orchestrator

**Files:**
- Create: `couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh`
- Create: `couplings/ibamr/tests/CpuLearnerConvergenceCompare.cmake`
- Create: `couplings/ibamr/tests/test_cpu_learner_validation_scripts.sh`
- Create: `couplings/ibamr/tests/fixtures/fake_cpu_learner_environment.sh`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Modify: `couplings/ibamr/README.md`

**Interfaces:**
- Runner arguments: `--source`, `--build`, `--run-root`, `--threads`, `--seed`, `--updates`, and `--training`.
- Target topology: one learner rank plus four single-rank synthetic environments.
- Target binding: five MPI ranks, four processing elements each, 20 logical CPUs total.
- Comparator returns `PASS`, `NO_SYNTHETIC_CONVERGENCE`, `CHECKPOINT_MISMATCH`, `UPDATE_NOT_OBSERVED`, `NONFINITE_UPDATE`, or `OPERATIONAL_INCOMPLETE`.

- [ ] **Step 1: Write script RED tests with a fake executable**

The fake must create controlled audit/evaluation outputs for these cases:

- valid improvement;
- unchanged policy error;
- non-finite update;
- missing update 1024;
- wrong seed;
- checkpoint digest mismatch;
- four-thread MSE more than 0.02 worse than one-thread;
- child operational timeout, which must be `OPERATIONAL_INCOMPLETE` and must
  not be called convergence failure.

- [ ] **Step 2: Implement immutable run preparation and core binding**

Reject dirty/mismatched source/build identities using the existing manifest
pattern. Verify `batchSize=8` and `batchSize % threads == 0`. Export:

```bash
OMP_NUM_THREADS="$threads"
OMP_DYNAMIC=FALSE
OMP_PROC_BIND=close
OMP_PLACES=cores
```

Launch with Open MPI binding equivalent to:

```bash
mpiexec --bind-to core --map-by slot:PE=4 -n 5 \
  "$executable" --nMasters 1 --nThreads "$threads" \
  --nEnvironments 4 --workerProcessesPerEnv 1 \
  --learnersOnWorkers 0 --nTrainSteps 1024 --randSeed "$seed" \
  --learnerAuditDir "$audit_dir" --restart none
```

Use the project's borrowed-MPI driver path and no process forking.

- [ ] **Step 3: Evaluate initial and final checkpoints without training**

For each training run, launch the same synthetic executable in evaluation mode
against `<audit-dir>/initial` and `<audit-dir>/final`, using the fixed 256-state
evaluation stream. Evaluation transitions must not be added to replay memory.
Require the restart audit digest to equal the corresponding saved digest.

- [ ] **Step 4: Implement the frozen comparator**

For every seed and thread count require:

- exactly 1024 update records and final step 1024;
- all audit and environment records finite;
- final 256-state action MSE at most 50 percent of initial MSE;
- final average return covers at least half the gap to zero;
- no residual exact-name learner/environment/mpiexec/prterun process.

For each seed require four-thread final MSE no more than one-thread MSE + 0.02
and absolute final-return difference no more than 0.02.

- [ ] **Step 5: Register only the fake fast test in ordinary CTest**

Label the real six-run matrix `node3;learner;convergence` and do not run it as
part of normal local CTest. The ordinary test exercises argument validation,
classification, ordering, and comparator logic with the fake executable.

- [ ] **Step 6: Update user documentation**

Document that this proves Smarties CPU learner behavior on the analytic task,
not eel policy quality. Include 1-thread and 4-thread examples and the exact
20-logical-CPU reservation.

- [ ] **Step 7: Commit Task 6**

```bash
git add couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh couplings/ibamr/tests/CpuLearnerConvergenceCompare.cmake couplings/ibamr/tests/test_cpu_learner_validation_scripts.sh couplings/ibamr/tests/fixtures/fake_cpu_learner_environment.sh couplings/ibamr/tests/CMakeLists.txt couplings/ibamr/README.md
git commit -m "test: add CPU learner convergence matrix"
```

---

### Task 7: Add the medium-eel one-update learner-activity gate

**Files:**
- Create: `couplings/ibamr/configs/training/cpu_learner_eel_activity.json`
- Create: `couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf`
- Create: `couplings/ibamr/tests/test_eel_learner_activity.cmake`
- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`
- Modify: `couplings/ibamr/scripts/run_node3.sh`
- Modify: `couplings/ibamr/tests/test_node3_scripts.sh`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Modify: `couplings/ibamr/README.md`

**Interfaces:**
- Adds launcher option: `--learner-threads N`, default 1.
- Adds manifest fields: `learner_threads`, `omp_proc_bind`, `omp_places`, `batch_size`, `network_precision_bytes`, and `learner_audit_dir`.
- Target topology: one learner rank, one two-rank medium IBAMR environment, four processing elements per rank, 12 logical CPUs total.
- Gate result: `PASS`, `UPDATE_NOT_OBSERVED`, `CHECKPOINT_MISMATCH`, `NONFINITE_UPDATE`, `COUPLING_PROTOCOL_FAILURE`, or `OPERATIONAL_INCOMPLETE`.

- [ ] **Step 1: Write launcher and wrapper RED tests**

Extend `test_node3_scripts.sh` to require:

- default `--nThreads 1` remains unchanged;
- `--learner-threads 4` reaches the Smarties command;
- `batchSize < threads` is rejected before MPI;
- `batchSize % threads != 0` is rejected before MPI;
- core binding reserves four processing elements per rank;
- manifest contains all new fields;
- PyTorch/Torch/CUDA flags never appear.

Create a fake activity log and make the wrapper fail on missing update, unchanged
digest, non-finite audit, point count other than 2932, missing terminal, restart
digest mismatch, or residual process.

- [ ] **Step 2: Add the dedicated validation settings**

Commit:

```json
{
  "learner": "VRACER",
  "batchSize": 4,
  "encoderLayerSizes": [0],
  "maxTotObsNum": 32,
  "minTotObsNum": 4,
  "nnLayerSizes": [16, 16],
  "obsPerStep": 1,
  "saveFreq": 1000000
}
```

The task fixture uses the existing bounded frequency action, `warmup_cycles=0`,
and `episode_decisions=5`. Mark target speed and reward values as diagnostic,
not calibrated policy-quality evidence.

- [ ] **Step 3: Add point count to the canonical eel transition record**

Read `environment.lagrangianPointCount()` after initialization and include
`lagrangian_points=%zu` in every `EEL_CONTROL` line. The count is observation
only; the existing layout invariant remains the enforcement point before shape
or velocity updates.

- [ ] **Step 4: Implement threaded launcher validation and binding**

Parse `--learner-threads`, extract integer `batchSize` from the frozen JSON,
and reject invalid combinations before build or MPI. For four-thread target
runs export the same OpenMP variables as Task 6 and add core binding with
`PE=4`. Pass `--learnerAuditDir` to Smarties. Preserve all existing topology,
revision, executable, and runtime-library identity checks.

- [ ] **Step 5: Implement checkpoint reload without a second IBAMR run**

After the eel run exits cleanly, use the synthetic executable in evaluation
mode to load the eel final audit checkpoint. Compare its `restart` parameter
digest with the final eel `final` digest and require finite actions on the
fixed evaluation states. Do not initialize PETSc or rerun eel for this check.

- [ ] **Step 6: Register the real gate as explicit node3-only**

The target command is:

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --envs 1 --ranks-per-env 2 --learner-ranks 1 --learner-threads 4 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-steps 1
```

Label the wrapper `physical;node3;learner` and do not include it in ordinary
local CTest.

- [ ] **Step 7: Run focused nonphysical GREEN tests**

Run script fixtures, audit comparator tests, precision tests, native update
tests, synthetic protocol smoke, borrowed MPI tests, eel control-task tests,
and layout invariant tests. Do not rerun the unrelated full 19-test suite or
the three-ratio physical frequency probe merely to satisfy this task.

- [ ] **Step 8: Commit Task 7**

```bash
git add couplings/ibamr/configs/training/cpu_learner_eel_activity.json couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf couplings/ibamr/tests/test_eel_learner_activity.cmake couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp couplings/ibamr/scripts/run_node3.sh couplings/ibamr/tests/test_node3_scripts.sh couplings/ibamr/tests/CMakeLists.txt couplings/ibamr/README.md
git commit -m "test: verify one native learner update on eel2d"
```

---

### Task 8: Package, run the gated node3 matrix, and review evidence

**Files:**
- Create ignored evidence: `.artifacts/ibamr-smarties-investigations/cpu-learner-validation-<revision>/`
- Create ignored task reports: `.superpowers/sdd/2026-08-14-smarties-cpu-learner-consistency-convergence/`
- Modify after verified results only: `couplings/ibamr/README.md`
- Modify only if the full closure gate passes: `experience/README.md`
- Create only if the full closure gate passes: `experience/verified/<atomic-record>.md`

**Interfaces:**
- Produces immutable package/source/build/run identities and an independently reviewed verdict for each layer.
- Does not rerun an admitted target after a functional failure.

- [ ] **Step 1: Verify the clean revision and package it**

Require `git status --short` empty and `git diff --check` clean. Package with
the existing allowlist script. Verify local package SHA-256, clean metadata,
zero included untracked files, and every source-manifest entry.

- [ ] **Step 2: Upload through the approved IBAMR staging directory**

Use:

```text
C:\Users\wumj\Project\IBAMR\.artifacts\stage2-upload\cpu-learner-validation-<revision>
```

Verify source, staging, and node3 archive SHA-256 values match before extract.
Use fresh source, build, and run paths containing the exact revision.

- [ ] **Step 3: Configure and build persistently on node3**

Source the approved IBAMR 0.18 environment, select GCC/G++ 8.5.0, configure
with `COMPILE_PY_SO=OFF`, `SINGLE_PRECISION=ON`, coupling and tests enabled, and
the fixed overlay. Start one persistent detached build wrapper that atomically
writes status and end time. Build only the targets required by Tasks 1-7.

- [ ] **Step 4: Prove runtime and precision identity**

Record executable and build-tree `libsmarties.so` SHA-256 values, RPATH/RUNPATH,
`ldd`, CMake cache values, compile definitions, `sizeof(nnReal)==4`, compiler,
Open MPI, PETSc, IBAMR, and overlay patch identities.

- [ ] **Step 5: Run only the focused prerequisite gate once**

Run the precision, audit, deterministic update, checkpoint, synthetic smoke,
borrowed-communicator, eel control, layout, launcher, and failure-classification
tests. Stop on a genuine prerequisite failure. An SSH client wait timeout is
not a test timeout; monitor the same persistent PID and never start an
unrecorded replacement.

- [ ] **Step 6: Run the frozen synthetic target matrix**

Sequentially run seeds 11, 29, and 47 with one thread, then the same seeds with
four threads. Each target is exactly once, uses 1024 updates, archives initial
and final evaluation, and records immediate exact-name process cleanup. Run the
frozen comparator only after all six admitted runs complete.

- [ ] **Step 7: Gate the eel run on synthetic PASS**

If any synthetic target is a functional failure, do not start eel. If all pass,
freeze the medium input, vertex, task, and training hashes; verify no stale
exact-name process; then run exactly one four-thread/two-environment-rank eel
activity target. Slow forward progress remains valid; only the internal
operational boundary can classify it incomplete.

- [ ] **Step 8: Perform independent evidence review**

The reviewer independently recomputes package/source/runtime hashes, parses
every audit record, checks exact update counts and seeds, verifies comparator
math, confirms checkpoint digests, checks 2932 points and MPI cleanup, and
distinguishes functional failures from operational interruption. The reviewer
must not rerun target probes or change evidence.

- [ ] **Step 9: Apply the experience admission gate**

Promote only atomic claims that have repeated target evidence, demonstrated
root cause where applicable, normal and relevant failure-path shutdown,
immutable revisions/commands/topologies, and independent review. Otherwise
leave the result in `.artifacts` and document it as partially verified.

- [ ] **Step 10: Commit documentation-only conclusions**

```bash
git add couplings/ibamr/README.md experience/README.md experience/verified
git commit -m "docs: record verified CPU learner boundaries"
```

Omit nonexistent or inadmissible experience paths from `git add`. The commit
must state that PyTorch/CUDA remain unsupported and that eel policy convergence
is not established.
