# Smarties Exact Update and Evaluation Termination Implementation Plan

> **Execution rule:** implement every production change through a failing test,
> then run focused verification before proceeding.

**Goal:** provide an exact native-CPU optimizer update budget and make frozen
policy evaluation terminate after the requested number of episodes.

**Architecture:** extend `ExecutionInfo` and `Engine` with an opt-in additional
gradient-update budget, use per-learner restart-aware baselines in the existing
worker loop, and count completed untracked episodes without inserting them into
replay. Preserve the driver-owned MPI topology and exclude PyTorch entirely.

**Tech stack:** C++14, Smarties native VRACER/network/Adam implementation,
OpenMP, MPI/Open MPI, CMake/CTest, Bash, node3 coupling build.

## Global constraints

- Keep `CouplingDriver` as sole MPI init/finalize owner.
- Keep learner and IBAMR environment ranks separate.
- Do not add PyTorch, CUDA, pybind11, Python bindings, or GPU code.
- Do not redefine `--nTrainSteps`.
- `--nTrainUpdates 0` must preserve current behavior.
- A positive update budget means additional updates in this invocation,
  including after checkpoint restart.
- Evaluation completion must not insert data into replay.
- Do not widen frozen numerical tolerances or reinterpret prior failed runs.

### Task 1: Exact optimizer-update termination

**Files:**

- Modify: `source/smarties/Settings/ExecutionInfo.h`
- Modify: `source/smarties/Settings/ExecutionInfo.cpp`
- Modify: `source/smarties/Engine.h`
- Modify: `source/smarties/Engine.cpp`
- Modify: `source/smarties/Core/Worker.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_exact_train_updates.cmake`

- [x] Add a real MPI synthetic RED test requesting two updates and asserting
      exact audit count/final step.
- [x] Add restart RED coverage for two additional updates.
- [x] Add `nTrainUpdates=0`, CLI parsing, and the C++ Engine setter.
- [x] Capture per-learner gradient baselines and stop on exact deltas.
- [x] Run the focused exact-update test and legacy CPU learner protocol.

### Task 2: Bounded evaluation without replay insertion

**Files:**

- Modify: `source/smarties/ReplayMemory/MemoryBuffer.cpp`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_cpu_learner_evaluation.cmake`

- [x] Add a bounded restart-evaluation RED test for two episodes.
- [x] Count a non-empty untracked terminal episode once without calling
      `addEpisodeToTrainingSet()`.
- [x] Require exit zero, exactly 64 decisions, two episodes, one summary, no
      training update records, and no residual processes.
- [x] Run the focused evaluation and related CPU learner/lifecycle tests.

### Task 3: Validation runner migration

**Files:**

- Modify: `couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh`
- Modify: `couplings/ibamr/tests/test_cpu_learner_validation_scripts.sh`
- Modify: `couplings/ibamr/README.md`

- [x] Change the training command from `--nTrainSteps "$updates"` to
      `--nTrainUpdates "$updates"` in a RED script fixture.
- [x] Keep evaluation on `--nEvalEpisodes 8` and preserve timeout/residual and
      runtime-identity gates.
- [x] Update documentation to distinguish transition and optimizer counters.
- [x] Run the complete runner fixture, syntax checks, and `git diff --check`.

### Task 4: node3 focused verification and frozen matrix

**Files:**

- Create ignored evidence under
  `.artifacts/ibamr-smarties-investigations/cpu-learner-validation-<revision>/`
- Update ignored task report under
  `.superpowers/sdd/2026-08-14-smarties-cpu-learner-consistency-convergence/`

- [ ] Commit a clean implementation revision and create a clean source
      package with metadata and source manifest.
- [ ] Upload through the approved IBAMR staging directory and verify archive
      hashes on both hosts.
- [ ] Configure with GCC/G++ 8.5, `SINGLE_PRECISION=ON`, and
      `COMPILE_PY_SO=OFF`; build only required targets.
- [ ] Run focused nonphysical tests before target simulations.
- [ ] Run the frozen synthetic matrix for seeds 11 and 29, thread counts 1 and
      2, and exactly 1024 updates; train with four environments and evaluate
      with one environment; do not rerun an admitted target.
- [ ] Verify finite updates, exact counts, parameter movement, same-setting
      repeatability, bounded checkpoint evaluation, and no scoped residuals.
- [ ] Keep eel2d and experience admission gated until the synthetic matrix
      passes and evidence is independently reviewed.
