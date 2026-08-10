# Eel Layout Fidelity Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail before time advancement when the official eel kinematics layout count differs from the loaded Lagrangian vertex count, support physical runs only at the official medium grid, and verify one real node3 medium run preserves all 2932 coordinates.

**Architecture:** Keep the official `IBEELKinematics` formulas and the fixed Smarties–IBAMR MPI ownership model. Add a pure count invariant called from `setImmersedBodyLayout()`, restrict the launcher to `medium`, and use the existing single-process response probe plus an independent Silo reader for physical verification. Invalid coarse/fine evidence remains isolated under `.artifacts`.

**Tech Stack:** C++14, CMake/CTest, Bash, MPI/Open MPI 5.0.9, GCC/G++ 8.5.0, IBAMR 0.18.0, PETSc 3.23.3, Silo 4.11, PowerShell packaging.

## Global Constraints

- The coupling driver remains the sole owner of `MPI_Init_thread()` and `MPI_Finalize()`.
- Smarties remains a borrowed-communicator CPU learner; no PyTorch, CUDA, pybind11, or Python runtime is added.
- Only environment ranks initialize PETSc/SAMRAI/IBTK/IBAMR; unrecoverable coupled failures use the existing coordinated `MPI_Abort` path.
- Do not change the official body envelope, deformation formula, phase law, point ordering, or shape-update equations.
- Physical eel2d execution supports only `N=64`, `MAX_LEVELS=3`, `REF_RATIO=4` in this phase.
- No old coarse calibration, response, or policy claim may enter `experience/verified`.
- All production changes follow RED–GREEN–REFACTOR and are committed in small, reviewable commits.

---

### Task 1: Add a pure Lagrangian layout-count invariant

**Files:**
- Create: `couplings/ibamr/cases/eel2d/EelLayoutInvariant.h`
- Create: `couplings/ibamr/cases/eel2d/EelLayoutInvariant.cpp`
- Create: `couplings/ibamr/tests/test_eel_layout_invariant.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt:9-14`
- Modify: `couplings/ibamr/tests/CMakeLists.txt:20-45`

**Interfaces:**
- Produces: `void requireEelLayoutPointCount(std::size_t layout_points, std::size_t lagrangian_points, const std::array<double, 2>& finest_mesh_width)` in namespace `ibamr_smarties::eel2d`.
- Throws: `std::invalid_argument` containing both counts and both mesh-width components when the counts differ.
- Consumes: only the C++ standard library; this function must remain independent of MPI, PETSc, SAMRAI, IBTK, and IBAMR.

- [ ] **Step 1: Write the failing unit test**

Create `test_eel_layout_invariant.cpp`:

```cpp
#include "EelLayoutInvariant.h"

#include <array>
#include <stdexcept>
#include <string>

namespace
{
bool rejects(const std::size_t layout_points,
             const std::size_t lagrangian_points,
             const std::string& expected_layout,
             const std::string& expected_lagrangian)
{
  try
  {
    ibamr_smarties::eel2d::requireEelLayoutPointCount(
      layout_points, lagrangian_points, { { 0.03125, 0.03125 } });
  }
  catch (const std::invalid_argument& error)
  {
    const std::string message(error.what());
    return message.find(expected_layout) != std::string::npos &&
           message.find(expected_lagrangian) != std::string::npos &&
           message.find("0.03125") != std::string::npos;
  }
  return false;
}
} // namespace

int main()
{
  ibamr_smarties::eel2d::requireEelLayoutPointCount(
    2932, 2932, { { 0.00390625, 0.00390625 } });
  if (!rejects(76, 2932, "76", "2932")) return 1;
  if (!rejects(11232, 2932, "11232", "2932")) return 2;
  return 0;
}
```

Add the target and CTest registration:

```cmake
add_executable(eel_layout_invariant_test test_eel_layout_invariant.cpp)
target_include_directories(eel_layout_invariant_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_layout_invariant_test PRIVATE ibamr_eel_control)
add_test(NAME eel_layout_invariant COMMAND eel_layout_invariant_test)
```

- [ ] **Step 2: Verify RED on node3 with a direct focused compile**

Upload only the new test into an isolated scratch directory and run:

```bash
/data2/mjwu/local/gcc-8.5.0/bin/g++ \
  -std=c++14 \
  -I/data2/mjwu/local/coupling-tdd/eel-layout-guard/cases/eel2d \
  /data2/mjwu/local/coupling-tdd/eel-layout-guard/tests/test_eel_layout_invariant.cpp \
  -o /data2/mjwu/local/coupling-tdd/eel-layout-guard/eel_layout_invariant_test
```

Expected: compile failure containing `EelLayoutInvariant.h: No such file or directory`. Record it under `.artifacts/ibamr-smarties-investigations/coarse-lagrangian-collapse/tdd-red/`.

- [ ] **Step 3: Implement the minimal invariant**

Create `EelLayoutInvariant.h`:

```cpp
#ifndef included_ibamr_smarties_EelLayoutInvariant
#define included_ibamr_smarties_EelLayoutInvariant

#include <array>
#include <cstddef>

namespace ibamr_smarties
{
namespace eel2d
{
void requireEelLayoutPointCount(
  std::size_t layout_points,
  std::size_t lagrangian_points,
  const std::array<double, 2>& finest_mesh_width);
} // namespace eel2d
} // namespace ibamr_smarties

#endif
```

Create `EelLayoutInvariant.cpp`:

```cpp
#include "EelLayoutInvariant.h"

#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{
void requireEelLayoutPointCount(
  const std::size_t layout_points,
  const std::size_t lagrangian_points,
  const std::array<double, 2>& finest_mesh_width)
{
  if (layout_points == lagrangian_points) return;
  std::ostringstream message;
  message << std::setprecision(17)
          << "eel kinematics layout point count " << layout_points
          << " does not match Lagrangian vertex count " << lagrangian_points
          << " at finest mesh width (" << finest_mesh_width[0]
          << ", " << finest_mesh_width[1] << ')';
  throw std::invalid_argument(message.str());
}
} // namespace eel2d
} // namespace ibamr_smarties
```

Add `cases/eel2d/EelLayoutInvariant.cpp` to `ibamr_eel_control`.

- [ ] **Step 4: Verify GREEN with the same direct compiler**

Upload the header and implementation and run:

```bash
/data2/mjwu/local/gcc-8.5.0/bin/g++ \
  -std=c++14 -Wall -Wextra -Werror \
  -I/data2/mjwu/local/coupling-tdd/eel-layout-guard/cases/eel2d \
  /data2/mjwu/local/coupling-tdd/eel-layout-guard/tests/test_eel_layout_invariant.cpp \
  /data2/mjwu/local/coupling-tdd/eel-layout-guard/cases/eel2d/EelLayoutInvariant.cpp \
  -o /data2/mjwu/local/coupling-tdd/eel-layout-guard/eel_layout_invariant_test
/data2/mjwu/local/coupling-tdd/eel-layout-guard/eel_layout_invariant_test
```

Expected: compile and executable both exit zero with no output.

- [ ] **Step 5: Commit the pure invariant**

```bash
git add couplings/ibamr/CMakeLists.txt \
        couplings/ibamr/cases/eel2d/EelLayoutInvariant.h \
        couplings/ibamr/cases/eel2d/EelLayoutInvariant.cpp \
        couplings/ibamr/tests/CMakeLists.txt \
        couplings/ibamr/tests/test_eel_layout_invariant.cpp
git commit -m "test: define eel layout count invariant"
```

### Task 2: Wire the invariant into official kinematics and add a negative integration test

**Files:**
- Modify: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp:28-35,213-259`
- Modify: `couplings/ibamr/tests/CMakeLists.txt:100-190`
- Create: `couplings/ibamr/tests/test_eel_layout_mismatch.cmake`

**Interfaces:**
- Consumes: `requireEelLayoutPointCount(...)` from Task 1.
- Produces: initialization-time rejection before `setShape()` when the reconstructed layout does not cover exactly the loaded Lagrangian index range.
- Keeps: the existing `d_ImmersedBodyData` construction and all kinematics formulas byte-for-byte except for count accumulation and the validation call.

- [ ] **Step 1: Add the failing coarse integration test before wiring the guard**

Render both inputs in `tests/CMakeLists.txt`:

```cmake
set(EEL_ENVIRONMENT_RUN_DIR "${CMAKE_CURRENT_BINARY_DIR}/eel-environment-smoke")
file(MAKE_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}")
execute_process(
  COMMAND "${CMAKE_COMMAND}"
    "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/coarse.conf"
    "-DOUTPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d.coarse"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/render_input.cmake"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND "${CMAKE_COMMAND}"
    "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/medium.conf"
    "-DOUTPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/render_input.cmake"
  COMMAND_ERROR_IS_FATAL ANY)
```

Create `test_eel_layout_mismatch.cmake`:

```cmake
foreach(required IN ITEMS TEST_EXECUTABLE MPIEXEC_EXECUTABLE INPUT_FILE)
  if(NOT DEFINED ${required} OR NOT EXISTS "${${required}}")
    message(FATAL_ERROR "${required} is missing: ${${required}}")
  endif()
endforeach()

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${TEST_EXECUTABLE}" "${INPUT_FILE}"
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE status
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  TIMEOUT 300)
string(CONCAT combined "${stdout}" "\n" "${stderr}")
if(status EQUAL 0)
  message(FATAL_ERROR "invalid coarse layout advanced instead of failing")
endif()
if(NOT combined MATCHES
   "layout point count 76 does not match Lagrangian vertex count 2932")
  message(FATAL_ERROR "missing layout mismatch diagnostic:\n${combined}")
endif()
```

Register it:

```cmake
add_test(
  NAME eel_layout_mismatch_guard
  COMMAND "${CMAKE_COMMAND}"
    "-DTEST_EXECUTABLE=$<TARGET_FILE:eel_environment_smoke>"
    "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
    "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
    "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
    "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
    "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d.coarse"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_layout_mismatch.cmake")
set_tests_properties(eel_layout_mismatch_guard PROPERTIES TIMEOUT 360)
```

- [ ] **Step 2: Verify RED in the node3 scratch build**

Configure/build the current task branch without integrating the call, then run:

```bash
ctest --test-dir "$BUILD_DIR" \
  -R '^eel_layout_mismatch_guard$' --output-on-failure
```

Expected: FAIL with `invalid coarse layout advanced instead of failing` because the existing executable completes one bad step.

- [ ] **Step 3: Integrate the minimal count check**

Add the include:

```cpp
#include "EelLayoutInvariant.h"
```

Immediately after constructing `d_ImmersedBodyData`, before maneuvering-axis setup, add:

```cpp
std::size_t layout_points = 0;
for (const auto& section : d_ImmersedBodyData)
  layout_points += static_cast<std::size_t>(section.second);
requireEelLayoutPointCount(
  layout_points,
  static_cast<std::size_t>(total_lag_pts),
  { { d_mesh_width[0], d_mesh_width[1] } });
```

Do not change the loops that compute `BodyNx`, `HeadNx`, section height, velocity, or shape.

- [ ] **Step 4: Verify GREEN for the pure and negative tests**

```bash
cmake --build "$BUILD_DIR" \
  --target eel_layout_invariant_test eel_environment_smoke -j2
ctest --test-dir "$BUILD_DIR" \
  -R '^(eel_layout_invariant|eel_layout_mismatch_guard)$' \
  --output-on-failure
```

Expected: 2/2 PASS. The negative test passes only because the child run exits nonzero with the exact count diagnostic.

- [ ] **Step 5: Verify the medium one-step environment path**

```bash
ctest --test-dir "$BUILD_DIR" \
  -R '^eel_environment_(smoke|control)$' --output-on-failure
```

Expected: 2/2 PASS using `input2d` rendered from `medium.conf`.

- [ ] **Step 6: Commit the wired guard**

```bash
git add couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp \
        couplings/ibamr/tests/CMakeLists.txt \
        couplings/ibamr/tests/test_eel_layout_mismatch.cmake
git commit -m "fix: reject mismatched eel layout fidelity"
```

### Task 3: Restrict node3 physical fidelity to medium and retract invalid calibration

**Files:**
- Modify: `couplings/ibamr/tests/test_node3_scripts.sh:116-333`
- Modify: `couplings/ibamr/scripts/run_node3.sh:17-35,143-219,381-435`
- Modify: `couplings/ibamr/README.md:70-165`
- Delete: `couplings/ibamr/configs/tasks/speed_tracking_node3_coarse.conf`

**Interfaces:**
- Produces: `run_node3.sh smoke|train` defaults to `--fidelity medium` and accepts only `medium`.
- Rejects: `coarse`, `fine`, and `curriculum` with exit code 65 and message `only medium is supported for physical eel2d runs` before build or MPI launch.
- Preserves: all topology arithmetic, manifest hashes, task validation, build freshness, failure injection, and MPI command construction for medium.

- [ ] **Step 1: Change script tests first**

Replace every valid-run `--fidelity coarse` with `--fidelity medium`; change fixture creation from `coarse.conf` to `medium.conf`. Remove the old curriculum-success assertions and add:

```bash
for invalid_fidelity in coarse fine curriculum; do
  log="$fixture_root/fidelity-${invalid_fidelity}.log"
  if capture_status "$log" \
    bash "$run_script" smoke --dry-run \
      --envs 1 --ranks-per-env 1 \
      --fidelity "$invalid_fidelity" \
      --training couplings/ibamr/configs/training/smoke.json \
      --smoke-steps 1; then
    fail "unsupported fidelity $invalid_fidelity was accepted"
  fi
  assert_contains "$(<"$log")" \
    "only medium is supported for physical eel2d runs"
  assert_not_contains "$(<"$log")" "COMMAND="
done
```

Add a default-fidelity assertion by omitting `--fidelity` from one dry run and requiring `FIDELITY=medium`.

- [ ] **Step 2: Verify RED**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
```

Expected: FAIL because coarse/curriculum are still accepted and the default remains coarse.

- [ ] **Step 3: Implement the launcher restriction**

Change help and default:

```bash
  --fidelity LEVEL         medium only (default: medium)
```

```bash
fidelity=medium
```

Replace the fidelity case with:

```bash
if [[ $fidelity != medium ]]; then
  die "only medium is supported for physical eel2d runs"
fi
```

Remove the unreachable curriculum-specific `--appSettings`, `--nStepPappSett`, multi-input rendering, and app-argument generation branches. Always call:

```bash
render_fidelity "$fidelity" "$run_dir/input2d"
```

- [ ] **Step 4: Verify GREEN and neighboring validation behavior**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
cmake -DCOUPLING_ROOT="$PWD/couplings/ibamr" \
  -P couplings/ibamr/tests/test_render_input.cmake
```

Expected: both commands exit zero. The script suite must still cover missing/malformed tasks, unreachable train steps, stale/tampered builds, topology arithmetic, task/config hashes, and failure-injection command generation.

- [ ] **Step 5: Retract invalid user-facing inputs**

Delete `speed_tracking_node3_coarse.conf`. Update README examples to use `--fidelity medium`, state that coarse/fine/curriculum are intentionally rejected, remove the calibrated-coarse target/direction claims, and link the investigation as invalid evidence only through its non-versioned artifact path. Do not create a medium target-speed config before recalibration.

- [ ] **Step 6: Run diff and static checks**

```bash
git diff --check
git grep -n -- '--fidelity coarse' -- couplings/ibamr || true
git grep -n 'speed_tracking_node3_coarse' -- couplings/ibamr || true
```

Expected: `git diff --check` exits zero; the two grep commands produce no supported-run references.

- [ ] **Step 7: Commit the support-surface change**

```bash
git add couplings/ibamr/scripts/run_node3.sh \
        couplings/ibamr/tests/test_node3_scripts.sh \
        couplings/ibamr/README.md
git add -u couplings/ibamr/configs/tasks/speed_tracking_node3_coarse.conf
git commit -m "fix: restrict eel physics to official grid fidelity"
```

### Task 4: Package and build the exact guard revision on node3

**Files:**
- Write raw evidence only: `.artifacts/stage2/layout-guard/$revision/`, where `$revision` is assigned from `git rev-parse HEAD` before the directory is created.
- Remote package: `/data2/mjwu/local/coupling-packages/`
- Remote source/build/run roots: `/data2/mjwu/local/coupling-{src,build,runs}/`

**Interfaces:**
- Consumes: the clean committed revision from Tasks 1-3.
- Produces: one immutable package, verified source manifest, build manifest, and executable SHA used by every following run.

- [ ] **Step 1: Run local static and packaging regression checks**

```powershell
$repo = 'C:\Users\wumj\Project\smarties\.worktrees\eel2d-frequency-control'
Set-Location $repo
& 'C:\Program Files\Git\usr\bin\bash.exe' -lc `
  'bash couplings/ibamr/tests/test_node3_scripts.sh'
cmake -DCOUPLING_ROOT="$repo/couplings/ibamr" `
  -P couplings/ibamr/tests/test_render_input.cmake
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File couplings/ibamr/tests/test_package_local.ps1
git -c safe.directory=C:/Users/wumj/Project/smarties/.worktrees/eel2d-frequency-control diff --check
git -c safe.directory=C:/Users/wumj/Project/smarties/.worktrees/eel2d-frequency-control status --short
```

Expected: all tests exit zero and Git status is empty apart from ignored `.artifacts`.

- [ ] **Step 2: Create and independently verify the immutable package**

```powershell
$revision = git -c safe.directory=C:/Users/wumj/Project/smarties/.worktrees/eel2d-frequency-control rev-parse HEAD
$short = $revision.Substring(0,12)
$out = Join-Path $repo '.artifacts\packages'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File couplings/ibamr/scripts/package_local.ps1 `
  -Repository $repo -OutputDirectory $out
$archive = Get-ChildItem $out -Filter "*-$short.tar.gz" |
  Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
Get-FileHash -Algorithm SHA256 $archive.FullName
```

Extract into `.artifacts/stage2/layout-guard/$revision/package_extract`, verify every `SOURCE_MANIFEST.sha256` entry, and require `SOURCE_METADATA.txt` to contain the exact value held in `$revision`, plus the two clean-source fields below:

```text
tracked_dirty=false
included_untracked_count=0
```

- [ ] **Step 3: Upload, re-hash, extract, and verify on node3**

Use the archive basename for all paths. In the node3 execution shell, assign `ARCHIVE_NAME` to the exact `$archive.Name` printed by the local packaging step before running these commands:

```bash
archive=/data2/mjwu/local/coupling-packages/$ARCHIVE_NAME
source_dir=/data2/mjwu/local/coupling-src/${ARCHIVE_NAME%.tar.gz}
sha256sum "$archive"
test ! -e "$source_dir"
mkdir -p "$source_dir"
tar -xzf "$archive" -C "$source_dir"
cd "$source_dir"
sha256sum -c SOURCE_MANIFEST.sha256 > manifest_check.log
test "$(wc -l < manifest_check.log)" -gt 0
cat SOURCE_METADATA.txt
```

Expected: remote archive SHA equals local SHA; every manifest item is `OK`; metadata identifies the exact clean revision.

- [ ] **Step 4: Build in a fresh node3 directory**

```bash
build_dir=/data2/mjwu/local/coupling-build/${ARCHIVE_NAME%.tar.gz}
bash "$source_dir/couplings/ibamr/scripts/build_node3.sh" \
  --source "$source_dir" --build "$build_dir"
cat "$build_dir/couplings/ibamr/build_manifest.txt"
sha256sum "$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
```

Expected: build exits zero; manifest revision/source/executable match; compiler is GCC/G++ 8.5.0; IBAMR is 0.18.0; PETSc is 3.23.3; the executable SHA independently matches the manifest.

- [ ] **Step 5: Run focused and full CTest**

```bash
ctest --test-dir "$build_dir" \
  -R '^(eel_layout_invariant|eel_layout_mismatch_guard|eel_environment_smoke|eel_environment_control|eel_smoke_protocol|eel_control_protocol)$' \
  --output-on-failure
ctest --test-dir "$build_dir" --output-on-failure
```

Expected: the focused set and then 100% of the full suite pass. Record actual durations; increase a timeout only after evidence shows a valid medium calculation exceeded the old bound while remaining computationally active.

### Task 5: Verify negative coarse rejection and a real official-grid medium case

**Files:**
- Remote evidence: `/data2/mjwu/local/coupling-runs/layout-guard-$short/`, where `$short` is the first 12 characters of the packaged revision.
- Local ignored mirror: `.artifacts/stage2/layout-guard/$revision/node3/`.
- Reuse the already demonstrated diagnostic source at `C:/Users/wumj/Project/IBAMR/.artifacts/stage2-upload/inspect_silo_points.c`; copy it into the ignored local evidence directory and upload that exact hashed file to the medium run directory.

**Interfaces:**
- Consumes: immutable node3 executable/build/source from Task 4.
- Produces: one expected coarse initialization failure and one successful medium ratio-1.0 single-process run with direct Silo coordinate evidence.

- [ ] **Step 1: Run the coarse negative case**

Create an isolated directory and copy the rendered input and official vertex before running the expected failure:

```bash
revision=$(awk -F= '$1 == "revision" { print $2 }' "$build_dir/couplings/ibamr/build_manifest.txt")
short=${revision:0:12}
run_root=/data2/mjwu/local/coupling-runs/layout-guard-$short
negative_dir=$run_root/coarse-negative
mkdir -p "$negative_dir"
cp "$build_dir/couplings/ibamr/tests/eel-environment-smoke/input2d.coarse" "$negative_dir/input2d.coarse"
cp "$source_dir/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex" "$negative_dir/eel2d.vertex"
cd "$negative_dir"
set +e
mpiexec -n 1 "$build_dir/couplings/ibamr/tests/eel_environment_smoke" \
  input2d.coarse > stdout.log 2>&1
status=$?
set -e
printf '%s\n' "$status" > exit_code.txt
```

Require nonzero status, the exact `layout point count 76 does not match Lagrangian vertex count 2932` diagnostic, no `EEL_CONTROL` transition, and an immediate process snapshot with no matching executable.

- [ ] **Step 2: Prepare the medium physical run**

Create a distinct run directory, copy the exact medium input and vertex, and upload the locally hashed `inspect_silo_points.c` into this directory:

```bash
medium_dir=$run_root/medium-ratio-1
mkdir -p "$medium_dir"
cd "$medium_dir"
cp "$build_dir/couplings/ibamr/tests/eel-environment-smoke/input2d" ./input2d
cp "$source_dir/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex" ./eel2d.vertex
sha256sum input2d eel2d.vertex inspect_silo_points.c \
  "$build_dir/couplings/ibamr/frequency_response_probe" \
  > input_hashes.txt
```

Confirm `input2d` contains `N = 64`, `MAX_LEVELS = 3`, and `REF_RATIO = 4`.

- [ ] **Step 3: Run one real medium decision**

```bash
mpiexec -n 1 "$build_dir/couplings/ibamr/frequency_response_probe" \
  --input-file input2d \
  --ratio 1.0 \
  --decisions 1 \
  --direction-x -0.991204416615555 \
  --direction-y 0.132339731304763 \
  > stdout.log 2>&1
printf '%s\n' "$?" > exit_code.txt
ps -eo pid,ppid,etimes,stat,cmd > process_snapshot_after.txt
```

Require exit zero, exactly one `EEL_FREQUENCY_PROBE` summary, one completed decision, positive elapsed time, at least one native IBAMR step, finite displacement/velocity, and phase error at most `1e-10` relative to `6.28 * ratio * elapsed_time`.

- [ ] **Step 4: Inspect actual Silo coordinates**

Compile the already demonstrated Silo reader against the node3 Silo 4.11 static library:

```bash
silo_root=/data2/mjwu/autoibamr-v0.18.0/packages/silo-4.11-bsd
/data2/mjwu/local/gcc-8.5.0/bin/gcc \
  -std=c99 -O2 -Wall -Wextra \
  -I"$silo_root/include" inspect_silo_points.c \
  "$silo_root/lib/libsilo.a" -lm -o inspect_silo_points
./inspect_silo_points \
  viz_eel2d_Str/lag_data.cycle_000000/lag_data.proc_0000.silo \
  viz_eel2d_Str/lag_data.cycle_000040/lag_data.proc_0000.silo \
  viz_eel2d_Str/lag_data.cycle_000080/lag_data.proc_0000.silo \
  | tee coordinate_summary.txt
```

Require for every row:

```text
nels=2932 unique=2932 max_multiplicity=1
```

Also require finite coordinate bounds and cycle/time values matching the requested files.

- [ ] **Step 5: Mirror and hash raw evidence locally**

Download commands, stdout, exit codes, process snapshots, coordinate summary, input hashes, and build/source manifests into `.artifacts/stage2/layout-guard/$revision/node3/`. Compute a local SHA-256 list for every downloaded file. Do not copy the result into `experience/verified`.

### Task 6: Review the narrow fix and hand back the corrected baseline

**Files:**
- Update ignored investigation: `.artifacts/ibamr-smarties-investigations/coarse-lagrangian-collapse/investigation.md`
- No verified experience file in this task.

**Interfaces:**
- Consumes: all code/test evidence from Tasks 1-5.
- Produces: a reviewed conclusion limited to fail-fast mismatch detection and official-grid coordinate preservation.

- [ ] **Step 1: Run final repository verification**

```bash
git diff --check
git status --short
git log -6 --oneline
ctest --test-dir "$build_dir" --output-on-failure
```

Expected: clean worktree, intended commits only, and 100% CTest pass for the same immutable revision used by the medium run.

- [ ] **Step 2: Independently inspect requirements and evidence**

Use `superpowers:requesting-code-review`. Review the design and every changed file, then separately inspect:

- the RED and GREEN outputs;
- package/source/build/executable hashes;
- coarse negative diagnostic and absence of transitions;
- medium exit code and phase equation;
- cycle 0/40/80 coordinate summary;
- successful and failure process snapshots.

Any unresolved Critical or Important issue blocks completion.

- [ ] **Step 3: Close only the demonstrated investigation scope**

Update the ignored investigation record with exact revision, environment, commands, actual results, and limitations. State explicitly that multi-fidelity support, medium speed calibration, grid convergence, full Smarties training admission, and policy quality remain pending.

- [ ] **Step 4: Report the handoff**

Report:

- final branch revision and executable SHA;
- exact node3 source/build/run paths;
- guard message and negative exit status;
- medium Silo coordinate counts for cycles 0/40/80;
- tests passed and measured duration;
- removed/disabled fidelity surfaces;
- the next task: recalibrate target speed at medium before restarting the full topology matrix.
