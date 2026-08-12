# Eel MPI-Decomposition Physical Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic gate that drives the official-medium eel2d environment with the same fixed actions on one and two MPI environment ranks, then compares the physical trajectory and formally computed reward.

**Architecture:** Extend the existing `frequency_response_probe` with a mutually exclusive task-driven fixed-action mode. Extract the adapter's interval forward-velocity calculation into a pure shared helper, expose the already validated global Lagrangian count read-only through the environment, and keep log parsing/comparison in a standalone CMake module. A wrapper runs the one-rank and two-rank probes sequentially in isolated directories; physical fields are authoritative and reward is a required derived check.

**Tech Stack:** C++14, CMake/CTest scripting, MPI, GCC/G++ 8.5.0, IBAMR 0.18.0, PETSc, SAMRAI, IBTK, existing Smarties CPU build, PowerShell/local packaging, node3 Open MPI environment.

## Global Constraints

- Apply `.agents/skills/ibamr-smarties-coupling/SKILL.md` and its fixed architecture contract to every task.
- The production coupling driver remains the sole MPI owner; Smarties remains a borrowed-communicator CPU learner, and no PyTorch, CUDA, pybind11, or Python runtime is added.
- The standalone diagnostic `MpiSession` owns exactly one `MPI_Init_thread()` and one final `MPI_Finalize()`; all ranks in its `MPI_COMM_WORLD` are environment ranks and initialize the CFD stack.
- No process forks after MPI initialization. A post-initialization probe failure reports on rank zero and calls `MPI_Abort(MPI_COMM_WORLD, 64)`; no rank privately finalizes MPI.
- Use only the official-medium physical case (`N=64`, `MAX_LEVELS=3`, `REF_RATIO=4`) for target evidence.
- The first comparison uses `speed_tracking_protocol.conf`, fixed action `1.0`, and two decisions, with no warmup.
- Exact integer checks include 2932 global Lagrangian points; physical tolerances are `abs=1e-12, rel=1e-12` for control/time/phase fields and `abs=1e-10, rel=1e-8` for COM/displacement/velocity/reward fields.
- Wall time and CPU utilization are context only. An operational timeout is `inconclusive`, never `physical mismatch`, and must not be silently rerun.
- Do not run the full 19-test suite or the three-ratio response sweep for this gate. Run only pure tests, focused build/link tests, focused fixed-action tests, and exactly one admitted node3 run at each rank count.
- Keep hypotheses and target evidence under `.artifacts/ibamr-smarties-investigations/`; do not write `experience/verified` unless the coupling skill's entire closure gate is independently satisfied.
- Each production change follows RED–GREEN–REFACTOR and ends in a small reviewable commit.

---

## File structure

- Create `couplings/ibamr/tests/EelConsistencyCompare.cmake`: pure parsing, validation, tolerance calculation, and two-stream comparison; it never launches MPI.
- Create `couplings/ibamr/tests/test_eel_consistency_compare.cmake`: fixture-driven positive and negative tests for the pure comparator.
- Create `couplings/ibamr/cases/eel2d/EelControlMeasurement.h/.cpp`: owns `ControlIntervalResult` plus the pure shared forward-velocity calculation used by both adapter and probe.
- Modify `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.h/.cpp`: retain the global Lagrangian count established by `getLagIdxRange()` and expose it read-only.
- Modify `couplings/ibamr/cases/eel2d/EelEnvironment.h/.cpp`: forward the read-only global point count.
- Modify `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`: replace its anonymous duplicate velocity calculation with the shared helper; no control behavior changes.
- Modify `couplings/ibamr/cases/eel2d/frequency_response_probe.cpp`: add task-driven fixed-action mode, canonical root-only records, and the post-initialization MPI fatal boundary while retaining direct-ratio mode.
- Create `couplings/ibamr/tests/test_eel_fixed_action_probe.cmake`: one-rank focused protocol/physics test for the new probe mode.
- Create `couplings/ibamr/tests/test_eel_mpi_consistency.cmake`: sequential one-rank/two-rank orchestration with isolated run directories and pure comparator invocation.
- Modify `couplings/ibamr/CMakeLists.txt` and `couplings/ibamr/tests/CMakeLists.txt`: register the shared library source and focused tests.
- Modify `couplings/ibamr/README.md`: document the diagnostic command, verdict semantics, and non-performance boundary.

---

### Task 1: Add the pure canonical-stream comparator

**Files:**
- Create: `couplings/ibamr/tests/EelConsistencyCompare.cmake`
- Create: `couplings/ibamr/tests/test_eel_consistency_compare.cmake`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `compare_eel_consistency_streams(ONE_STREAM <text> TWO_STREAM <text> EXPECTED_DECISIONS <uint> OUT_VERDICT <var> OUT_REPORT <var>)`.
- Returns: `OUT_VERDICT=PASS`, `PHYSICAL_MISMATCH`, `REWARD_MISMATCH`, or `MALFORMED`; `OUT_REPORT` identifies the first failing field and decision.
- Consumes: canonical `EEL_FIXED_ACTION_STEP` and `EEL_FIXED_ACTION_SUMMARY` text defined by the approved spec; no executable, MPI, IBAMR, or filesystem state.

- [ ] **Step 1: Write the failing comparator fixture test**

Create `test_eel_consistency_compare.cmake` with a helper that invokes the not-yet-existing function on literal streams. Use two step lines and one summary per stream. The baseline stream must include every required field:

```cmake
include("${COMPARE_MODULE}")

set(one_stream [=[
EEL_FIXED_ACTION_STEP decision=1 environment_ranks=1 action=1 target_ratio=1.5 previous_ratio=1 applied_ratio=1.1 start_time=0 end_time=0.1251 ibamr_steps=1251 start_com_x=0 start_com_y=0 end_com_x=0.01 end_com_y=0 displacement_x=0.01 displacement_y=0 forward_displacement=0.01 forward_velocity=0.07993605115907275 phase_end=0.785628 lagrangian_points=2932 reward_tracking=-0.057648 reward_frequency=-0.03 reward_smoothness=-0.04 reward_total=-0.127648
EEL_FIXED_ACTION_STEP decision=2 environment_ranks=1 action=1 target_ratio=1.5 previous_ratio=1.1 applied_ratio=1.2 start_time=0.1251 end_time=0.2502 ibamr_steps=1251 start_com_x=0.01 start_com_y=0 end_com_x=0.021 end_com_y=0 displacement_x=0.011 displacement_y=0 forward_displacement=0.011 forward_velocity=0.08792965627498002 phase_end=1.649256 lagrangian_points=2932 reward_tracking=-0.05023 reward_frequency=-0.12 reward_smoothness=-0.04 reward_total=-0.21023
EEL_FIXED_ACTION_SUMMARY environment_ranks=1 decisions=2 ibamr_steps=2502 elapsed_time=0.2502 displacement_x=0.021 displacement_y=0 forward_displacement=0.021 final_phase=1.649256 lagrangian_points=2932 reward_tracking=-0.107878 reward_frequency=-0.15 reward_smoothness=-0.08 reward_total=-0.337878
]=])
string(REPLACE "environment_ranks=1" "environment_ranks=2" two_stream "${one_stream}")

compare_eel_consistency_streams(
  ONE_STREAM "${one_stream}" TWO_STREAM "${two_stream}"
  EXPECTED_DECISIONS 2 OUT_VERDICT verdict OUT_REPORT report)
if(NOT verdict STREQUAL "PASS")
  message(FATAL_ERROR "identical physical streams did not pass: ${report}")
endif()
```

Add independent cases which mutate `end_com_x` outside tolerance, mutate only `reward_total`, set `lagrangian_points=76`, insert `nan`, remove step 2, and duplicate step 1. Require respectively `PHYSICAL_MISMATCH`, `REWARD_MISMATCH`, and `MALFORMED`; each report must name the offending field or structural error.

- [ ] **Step 2: Register and run RED**

Add:

```cmake
add_test(
  NAME eel_consistency_compare
  COMMAND "${CMAKE_COMMAND}"
    "-DCOMPARE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/EelConsistencyCompare.cmake"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_consistency_compare.cmake")
```

Run from the existing build directory:

```bash
ctest --test-dir BUILD -R '^eel_consistency_compare$' --output-on-failure
```

Expected RED: CMake cannot include `EelConsistencyCompare.cmake` or cannot find `compare_eel_consistency_streams`.

- [ ] **Step 3: Implement strict parsing and comparison**

Create `EelConsistencyCompare.cmake` with these exact helpers:

```cmake
function(eel_read_field line key output)
  string(REGEX MATCH "(^| )${key}=([^ ]+)" match "${line}")
  if(NOT match)
    set(${output} "" PARENT_SCOPE)
    return()
  endif()
  set(${output} "${CMAKE_MATCH_2}" PARENT_SCOPE)
endfunction()

function(eel_within_tolerance left right absolute relative output difference limit)
  execute_process(
    COMMAND "${AWK_EXECUTABLE}" -v "a=${left}" -v "b=${right}"
            -v "atol=${absolute}" -v "rtol=${relative}"
            "BEGIN { d=a-b; if (d<0) d=-d; aa=a; if (aa<0) aa=-aa;
                     bb=b; if (bb<0) bb=-bb; m=aa>bb?aa:bb;
                     lim=atol+rtol*m; printf \"%.17g %.17g %d\", d, lim, d<=lim; }"
    OUTPUT_VARIABLE result COMMAND_ERROR_IS_FATAL ANY)
  string(REPLACE " " ";" parts "${result}")
  list(GET parts 0 parsed_difference)
  list(GET parts 1 parsed_limit)
  list(GET parts 2 parsed_pass)
  set(${difference} "${parsed_difference}" PARENT_SCOPE)
  set(${limit} "${parsed_limit}" PARENT_SCOPE)
  if(parsed_pass EQUAL 1)
    set(${output} TRUE PARENT_SCOPE)
  else()
    set(${output} FALSE PARENT_SCOPE)
  endif()
endfunction()

function(compare_eel_consistency_streams)
  cmake_parse_arguments(ARG "" "ONE_STREAM;TWO_STREAM;EXPECTED_DECISIONS;OUT_VERDICT;OUT_REPORT" "" ${ARGN})
endfunction()
```

Complete `compare_eel_consistency_streams` by normalizing CRLF to LF, splitting
on newlines, and selecting lines whose prefixes are exactly
`EEL_FIXED_ACTION_STEP ` or `EEL_FIXED_ACTION_SUMMARY `. Require exactly
`ARG_EXPECTED_DECISIONS` steps and one summary per stream. For list index `i`,
require decision `i+1`, ranks 1 and 2 respectively, and point count 2932. Read
every canonical field with `eel_read_field`, reject missing or nondecimal
values, and compare in this order: exact integers; control/time/phase; physical
COM/displacement/velocity; reward. Set the caller-named output variables with
`PARENT_SCOPE` at the first failure. If no check fails, set `PASS` and
`all fields match`. Count occurrences of ` key=` before reading so duplicate
fields are `MALFORMED`, not silently accepted.

The implementation must reject `nan`, `inf`, missing fields, duplicate fields, duplicate records, and trailing text inside a value. Report format is:

```text
decision=<N> field=<KEY> one=<VALUE> two=<VALUE> difference=<D> tolerance=<T>
```

and structural errors begin `malformed:`.

- [ ] **Step 4: Run focused GREEN and diff checks**

```bash
ctest --test-dir BUILD -R '^eel_consistency_compare$' --output-on-failure
git diff --check
```

Expected: one focused test passes; diff check is empty.

- [ ] **Step 5: Commit the comparator**

```bash
git add couplings/ibamr/tests/EelConsistencyCompare.cmake \
        couplings/ibamr/tests/test_eel_consistency_compare.cmake \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "test: add eel MPI consistency comparator"
```

---

### Task 2: Share control measurements and expose the validated point count

**Files:**
- Create: `couplings/ibamr/cases/eel2d/EelControlMeasurement.h`
- Create: `couplings/ibamr/cases/eel2d/EelControlMeasurement.cpp`
- Create: `couplings/ibamr/tests/test_eel_control_measurement.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Modify: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.h`
- Modify: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp`
- Modify: `couplings/ibamr/cases/eel2d/EelEnvironment.h`
- Modify: `couplings/ibamr/cases/eel2d/EelEnvironment.cpp`
- Modify: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`

**Interfaces:**
- Produces: `ControlIntervalResult` and `double forwardVelocity(const ControlIntervalResult&, const EelTaskConfig&)` in namespace `ibamr_smarties::eel2d`.
- Produces: `std::size_t IBEELKinematics::getGlobalLagrangianPointCount() const` and `std::size_t EelEnvironment::globalLagrangianPointCount() const`.
- Consumes: existing `ControlIntervalResult`, `EelTaskConfig`, and the constructor's `getLagIdxRange()` result. The count is global and immutable after eel initialization.

- [ ] **Step 1: Write RED unit tests for the shared measurement**

Move the existing `ControlIntervalResult` definition from `EelEnvironment.h`
to `EelControlMeasurement.h`; `EelEnvironment.h` includes that header so all
existing callers retain the same type name. Create
`test_eel_control_measurement.cpp`:

```cpp
#include "EelControlMeasurement.h"

#include <cmath>
#include <stdexcept>

using namespace ibamr_smarties::eel2d;

int main()
{
  EelTaskConfig config{};
  config.forward_direction_x = 0.6;
  config.forward_direction_y = 0.8;
  ControlIntervalResult interval{ 1.0, 1.5, {{2.0, 3.0}}, {{2.3, 3.4}}, 5 };
  if (std::abs(forwardVelocity(interval, config) - 1.0) > 1.0e-14) return 1;
  interval.end_time = interval.start_time;
  try { forwardVelocity(interval, config); }
  catch (const std::runtime_error&) { return 0; }
  return 2;
}
```

Register `eel_control_measurement_test`, link it to `ibamr_eel_control`, and add `EelControlMeasurement.cpp` to `ibamr_eel_control`.

- [ ] **Step 2: Run RED**

```bash
cmake --build BUILD --target eel_control_measurement_test -j2
```

Expected RED: missing `EelControlMeasurement.h`.

- [ ] **Step 3: Implement the pure helper and reuse it in the adapter**

Declare and define the exact public function. Move the existing elapsed-time,
direction projection, and finite checks byte-for-byte from the adapter into
`EelControlMeasurement.cpp`. Include the new header in
`EelSmartiesAdapter.cpp` and delete only its anonymous `forwardVelocity`.

- [ ] **Step 4: Establish RED for the read-only point-count accessors**

Add compile-time use in `test_eel_environment_control.cpp` immediately after
initialization:

```cpp
if (environment.globalLagrangianPointCount() != 2932) return 7;
```

Run:

```bash
cmake --build BUILD --target eel_environment_control -j2
```

Expected RED: `EelEnvironment` has no member `globalLagrangianPointCount`.

- [ ] **Step 5: Retain and expose the constructor-established global count**

In `IBEELKinematics`, add a private `std::size_t d_global_lagrangian_point_count = 0;`, assign it from `total_lag_pts` in `setImmersedBodyLayout()` before the existing invariant call, and add:

```cpp
std::size_t getGlobalLagrangianPointCount() const;
```

Forward it through `EelEnvironment::Impl` and `EelEnvironment`:

```cpp
std::size_t globalLagrangianPointCount() const;
```

Both environment implementations throw `std::logic_error` before initialization. Do not derive this count from PETSc local vector sizes or reopen `eel2d.vertex`.

- [ ] **Step 6: Run focused GREEN**

```bash
cmake --build BUILD --target eel_control_measurement_test eel_environment_control -j2
ctest --test-dir BUILD -R '^(eel_control_measurement|eel_control_task)$' --output-on-failure
git diff --check
```

Expected: both pure tests pass and both IBAMR targets link. Do not run the real environment CTest in this task; Task 3 exercises the accessor in one admitted short run.

- [ ] **Step 7: Commit the shared measurement and accessor**

```bash
git add couplings/ibamr/CMakeLists.txt couplings/ibamr/tests/CMakeLists.txt \
        couplings/ibamr/cases/eel2d/EelControlMeasurement.h \
        couplings/ibamr/cases/eel2d/EelControlMeasurement.cpp \
        couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp \
        couplings/ibamr/cases/eel2d/EelEnvironment.h \
        couplings/ibamr/cases/eel2d/EelEnvironment.cpp \
        couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.h \
        couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp \
        couplings/ibamr/tests/test_eel_control_measurement.cpp \
        couplings/ibamr/tests/test_eel_environment_control.cpp
git commit -m "refactor: share eel control measurements"
```

---

### Task 3: Add task-driven fixed-action probe records

**Files:**
- Modify: `couplings/ibamr/cases/eel2d/frequency_response_probe.cpp`
- Create: `couplings/ibamr/tests/test_eel_fixed_action_probe.cmake`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `loadEelTaskConfig`, `EelControlTask`, shared `forwardVelocity`, and `EelEnvironment::globalLagrangianPointCount()`.
- Produces: mutually exclusive `--task-file PATH --action A` probe mode and root-only `EEL_FIXED_ACTION_STEP`/`EEL_FIXED_ACTION_SUMMARY` records.
- Preserves: existing `--ratio R --direction-x X --direction-y Y` output and behavior.

- [ ] **Step 1: Write RED for task mode and canonical output**

Create `test_eel_fixed_action_probe.cmake`. It must run one MPI rank in the existing medium fixture directory:

```cmake
execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}"
          --input-file "${INPUT_FILE}"
          --task-file "${TASK_FILE}"
          --action 1.0 --decisions 2
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE status OUTPUT_VARIABLE stdout ERROR_VARIABLE stderr)
```

Assert exit zero, exactly two `EEL_FIXED_ACTION_STEP` lines, one summary, applied ratios exactly 1.1 and 1.2, `lagrangian_points=2932`, positive per-step times and step counts, finite physics/reward fields, summary decisions 2, total steps equal the two step counts, and cumulative rewards equal the two per-step sums within `1e-12`.

Also invoke parser-only invalid combinations before IBAMR initialization:

- both `--ratio` and `--task-file`;
- task mode without `--action`;
- direct mode with `--action`;
- task file with nonzero warmup;
- decisions greater than the task horizon.

Each must exit 64 and name the invalid contract.

- [ ] **Step 2: Register and run RED without a timeout verdict**

Register `eel_fixed_action_probe` with the current medium fixture, task fixture, and working directory. Give CTest a generous safety ceiling of 900 seconds, but do not encode duration as a correctness assertion.

```bash
cmake --build BUILD --target frequency_response_probe -j2
ctest --test-dir BUILD -R '^eel_fixed_action_probe$' --output-on-failure
```

Expected RED: old probe rejects `--task-file` as an unknown option.

- [ ] **Step 3: Implement the two explicit option modes**

Extend `ProbeOptions` with `task_file`, `action`, `has_action`, and a mode enum. Validate all required/mutually-exclusive options before creating `MpiSession`. Load the task and reject nonzero warmup or decisions above the horizon before `environment.initialize`.

After `MpiSession` exists, query `MPI_Comm_rank` and `MPI_Comm_size`. In task mode, run exactly the approved production ordering for every decision and print the canonical step on rank zero. Accumulate integer steps, elapsed/displacement, and the four reward fields, then print the canonical summary on rank zero. Flush each record.

Do not change direct-ratio control interval, direct-mode fields, or its existing `EEL_FREQUENCY_PROBE` line.

- [ ] **Step 4: Add the post-initialization fatal boundary**

Track whether distributed environment initialization completed. Refactor `main` so validation errors before initialization retain the exact `frequency response probe error: ...` diagnostic and return 64. For exceptions after initialization, rank zero prints:

```text
frequency response probe fatal error: <message>
```

then all paths call `MPI_Abort(MPI_COMM_WORLD, 64)` and `std::abort()`. Add the
hidden test-only `--fault-after-initialize` option and make it throw immediately
after `environment.initialize`. Extend the focused wrapper to require the exact
fatal diagnostic, `MPI_ABORT was invoked`, and error code 64; an unrelated
missing-input failure must not satisfy this assertion.

- [ ] **Step 5: Run focused GREEN**

```bash
cmake --build BUILD --target frequency_response_probe -j2
ctest --test-dir BUILD -R '^(eel_consistency_compare|eel_fixed_action_probe)$' --output-on-failure
git diff --check
```

Expected: pure comparator and one-rank task-driven probe pass. Do not run `frequency_response_probe`'s three-ratio sweep here.

- [ ] **Step 6: Commit fixed-action mode**

```bash
git add couplings/ibamr/cases/eel2d/frequency_response_probe.cpp \
        couplings/ibamr/tests/test_eel_fixed_action_probe.cmake \
        couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: add deterministic eel action probe"
```

---

### Task 4: Orchestrate the one-rank/two-rank gate and document it

**Files:**
- Create: `couplings/ibamr/tests/test_eel_mpi_consistency.cmake`
- Create: `couplings/ibamr/tests/test_eel_mpi_consistency_orchestration.cmake`
- Create: `couplings/ibamr/tests/fixtures/fake_eel_fixed_action_probe.cmake`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`
- Modify: `couplings/ibamr/README.md`

**Interfaces:**
- Consumes: `frequency_response_probe`, the medium run fixture, `speed_tracking_protocol.conf`, and `compare_eel_consistency_streams`.
- Produces: CTest `eel_mpi_consistency`, sequential isolated run directories, captured child logs, and a `PASS`/mismatch/inconclusive report.

- [ ] **Step 1: Write orchestration RED against a fake probe**

Before spending CFD time, make the script testable with `PROBE_EXECUTABLE` and MPI variables injected. Add a `DRY_FIXTURE_MODE` branch used only by CTest that invokes a tiny CMake fake-probe fixture and confirms the wrapper:

- creates distinct `rank-1` and `rank-2` directories;
- passes `--task-file`, `--action 1.0`, and `--decisions 2` identically;
- captures separate stdout/stderr/status files;
- passes streams to the pure comparator;
- returns a `PASS` report for matching streams;
- returns nonzero and `PHYSICAL_MISMATCH` for an injected COM mutation;
- writes `INCONCLUSIVE_OPERATIONAL_TIMEOUT` when a child result is explicitly classified as timeout, without calling the physics comparator.

Run with exact repository paths:

```bash
cmake \
  -DORCHESTRATOR=$PWD/couplings/ibamr/tests/test_eel_mpi_consistency.cmake \
  -DFAKE_PROBE=$PWD/couplings/ibamr/tests/fixtures/fake_eel_fixed_action_probe.cmake \
  -P $PWD/couplings/ibamr/tests/test_eel_mpi_consistency_orchestration.cmake
```

Expected RED: the orchestration script does not exist.

- [ ] **Step 2: Implement sequential isolated execution**

In `test_eel_mpi_consistency.cmake`, define one function that accepts a rank count and run directory, copies only `input2d`, `eel2d.vertex`, and `task.conf`, executes MPI with the fixed arguments, and returns status/stdout/stderr. Run rank 1 to completion before launching rank 2. Never share a working directory.

On a nonzero child exit, emit `MALFORMED` with the child status unless the launcher explicitly reports its operational timeout classification. On two successful children, invoke `compare_eel_consistency_streams` and make CMake fatal only after writing the report. Do not compare wall times.

- [ ] **Step 3: Register the dry fixture test and the real focused gate**

Register the dry fixture with the exact files above. Register the real test as:

```cmake
add_test(
  NAME eel_mpi_consistency
  COMMAND "${CMAKE_COMMAND}"
    "-DPROBE_EXECUTABLE=$<TARGET_FILE:frequency_response_probe>"
    "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
    "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
    "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
    "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
    "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
    "-DVERTEX_FILE=${EEL_ENVIRONMENT_RUN_DIR}/eel2d.vertex"
    "-DTASK_FILE=${EEL_ENVIRONMENT_RUN_DIR}/task.conf"
    "-DCOMPARE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/EelConsistencyCompare.cmake"
    "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/eel-mpi-consistency"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_mpi_consistency.cmake")
```

The real test receives the actual probe/MPI/input/task paths. Set only an outer safety timeout large enough for two sequential medium runs; document that timeout as an inconclusive operational boundary rather than a physics criterion. Label the real test `physical;node3` so ordinary local pure-test selections can exclude it.

- [ ] **Step 4: Run dry GREEN and review the real command without launching it**

```bash
ctest --test-dir BUILD -R '^(eel_consistency_compare|eel_mpi_consistency_orchestration)$' --output-on-failure
ctest --test-dir BUILD -N -V -R '^eel_mpi_consistency$'
```

Expected: pure and orchestration fixtures pass; verbose listing shows exactly one rank-1 and one rank-2 sequence, fixed action 1.0, two decisions, and separate directories. Do not execute the real gate locally in this step.

- [ ] **Step 5: Document scope and verdict semantics**

In `couplings/ibamr/README.md`, add one short section containing the direct CTest selection and these explicit claims:

- it compares one versus two environment ranks on the official-medium case;
- physics and derived reward are compared, not speed;
- timeout means inconclusive, not physical mismatch;
- passing does not prove scaling, long-horizon stability, resets, training convergence, or policy quality.

- [ ] **Step 6: Run focused static regression and commit**

```bash
ctest --test-dir BUILD -R '^(eel_consistency_compare|eel_control_measurement|eel_control_task|eel_mpi_consistency_orchestration)$' --output-on-failure
git diff --check
git status --short
```

Then:

```bash
git add couplings/ibamr/tests/test_eel_mpi_consistency.cmake \
        couplings/ibamr/tests/test_eel_mpi_consistency_orchestration.cmake \
        couplings/ibamr/tests/CMakeLists.txt couplings/ibamr/README.md
git commit -m "test: add eel MPI physical consistency gate"
```

---

### Task 5: Package and run the admitted node3 comparison

**Files:**
- Create ignored evidence: `.artifacts/ibamr-smarties-investigations/eel-mpi-decomposition-consistency-$short/`, where Step 1 defines `$short`.
- Modify only after a verification defect has first been reproduced by a new
  RED test: the exact source/test file from Tasks 1–4 that owns that defect.

**Interfaces:**
- Consumes: a clean committed revision, `couplings/ibamr/scripts/package_local.ps1`, GCC/G++ 8.5.0, `/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh`, official-medium rendered input, task fixture, and exact executable/runtime-library identities.
- Produces: immutable source/package/build/run manifests plus one admitted rank-1 result, one admitted rank-2 result, comparator report, and immediate exact-name process snapshots.

- [ ] **Step 1: Verify the local revision and create an immutable package**

Require:

```bash
git status --short
git diff --check
revision=$(git rev-parse HEAD)
short=$(git rev-parse --short=12 HEAD)
```

Expected: clean tracked worktree and exact committed revision. Run:

```powershell
.\couplings\ibamr\scripts\package_local.ps1 `
  -Repository (Get-Location).Path `
  -OutputDirectory .artifacts\packages
```

Record archive SHA-256, `SOURCE_METADATA.txt`, and every
`SOURCE_MANIFEST.sha256` check. Require `tracked_dirty=false` and
`included_untracked_count=0`.

- [ ] **Step 2: Upload through the approved local archive path and verify before extraction**

Stage under
`C:\Users\wumj\Project\IBAMR\.artifacts\stage2-upload\eel-mpi-consistency-$short\`
if direct worktree transfer is rejected. Upload to
`/data2/mjwu/local/coupling-packages/`, extract to
`/data2/mjwu/local/coupling-src/smarties-ibamr-$short/`, and build under
`/data2/mjwu/local/coupling-build/smarties-ibamr-$short/`. Require
local, staging, and node3 archive SHA-256 equality, every manifest entry `OK`,
and zero unexpected source files before building.

- [ ] **Step 3: Build only the required targets with the fixed environment**

Source the node3 IBAMR 0.18 environment, select GCC/G++ 8.5.0, configure the immutable source, and build:

```bash
cmake --build BUILD --target frequency_response_probe eel_control_measurement_test -j2
```

Record compiler, MPI, IBAMR/PETSc, executable SHA, runtime `libsmarties.so` path/SHA, RPATH, and `ldd`. Run only the pure/focused nonphysical tests:

```bash
ctest --test-dir BUILD -R '^(eel_consistency_compare|eel_control_measurement|eel_control_task|eel_mpi_consistency_orchestration)$' --output-on-failure
```

- [ ] **Step 4: Freeze target inputs and pre-run process boundary**

Create one evidence directory containing copies and SHA-256 values for the rendered official-medium `input2d`, `eel2d.vertex`, and `speed_tracking_protocol.conf`. Verify `N=64`, `MAX_LEVELS=3`, `REF_RATIO=4`, `warmup_cycles=0`, action 1.0, decisions 2, and global expected count 2932. Record an exact-name pre-run snapshot for `frequency_response_probe`, `mpiexec`, and `prterun`; do not start if a matching stale process exists.

- [ ] **Step 5: Execute exactly one admitted rank-1 probe**

Run the exact task-driven command in a fresh `rank-1` directory. Preserve command, stdout, stderr, status, start/end timestamps, and an immediate exact-name post-run snapshot. Admission requires exit zero, two canonical steps, one summary, environment size 1, global count 2932, and no residual process. Wall time is informational.

If an operational timeout occurs, stop with `INCONCLUSIVE_OPERATIONAL_TIMEOUT`; do not start rank 2 or rerun.

- [ ] **Step 6: Execute exactly one admitted rank-2 probe**

Only after rank 1 passes its structural/shutdown checks, run the corresponding command in a fresh `rank-2` directory with the same immutable inputs and arguments. Preserve the same artifacts. Admission requires exit zero, two canonical steps, one summary, environment size 2, global count 2932, and no residual process.

If an operational timeout occurs, stop as inconclusive; do not rerun.

- [ ] **Step 7: Compare and classify the evidence**

Invoke `EelConsistencyCompare.cmake` on the two captured streams. Preserve its exact report. A `PASS` requires all authoritative physics and derived reward fields within the frozen tolerances. A numerical disagreement remains `PHYSICAL_MISMATCH` or `REWARD_MISMATCH`; do not widen tolerances after seeing the result.

- [ ] **Step 8: Run only completion-focused verification and write the report**

Re-run the pure comparator against the archived outputs, independently recalculate package/executable/runtime/input/task hashes, and verify delayed process absence while labelling it as delayed evidence. Do not run the full 19-test suite or the three-ratio frequency test.

Write an investigation report containing exact revision, environment, topology, commands, expected/actual results, artifacts, limitations, and one of `PASS`, `PHYSICAL_MISMATCH`, `REWARD_MISMATCH`, `MALFORMED`, or `INCONCLUSIVE_OPERATIONAL_TIMEOUT`.

- [ ] **Step 9: Apply the experience closure gate**

Do not promote this single rank-1/rank-2 pair by itself. Check every item in `.agents/skills/ibamr-smarties-coupling/references/experience-admission.md`. If repetition or another required lifecycle item is absent, leave the validated report under `.artifacts` and state `experience promotion pending`; do not create or edit `experience/verified`.

---

## Final review boundary

Before any merge or push, request an independent code-and-evidence review scoped to the commits created by this plan. The reviewer must inspect MPI ownership, root-only output, the point-count source, tolerance implementation, malformed/reward/physical negative fixtures, exact node3 commands, process snapshots, and artifact hashes. A passing physics result does not override an Important or Critical review finding.
