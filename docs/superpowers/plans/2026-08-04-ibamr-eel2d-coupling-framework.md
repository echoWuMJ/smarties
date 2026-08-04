# IBAMR eel2d Coupling Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the first-stage IBAMR 0.18.0 eel2d lifecycle coupling inside Smarties, with single-owner MPI, a one-command node3 smoke workflow, and local-first source archival.

**Architecture:** A Coupling Driver owns MPI and passes its communicator to the existing external-communicator Smarties `Engine` constructor. Smarties partitions learner and environment ranks; only environment callbacks initialize PETSc/IBTK/IBAMR and run an eel2d lifecycle probe. All coupling code lives under `couplings/ibamr/`; node3 builds immutable local snapshots and returns logs to local artifacts.

**Tech Stack:** C++14, MPI 5.0.9, Smarties C++ core, IBAMR 0.18.0, PETSc 3.23.3, CMake 3.30.6, Bash, PowerShell, GCC/G++ 8.5.0.

## Global Constraints

- Work on branch `feature/ibamr-eel2d-coupling`; do not develop directly on `master`.
- Keep all new integration source under `couplings/ibamr/`; Smarties core changes are limited to borrowed-MPI ownership and build integration.
- The Coupling Driver is the sole owner of `MPI_Init_thread()` and `MPI_Finalize()` in embedded mode.
- Request at least `MPI_THREAD_SERIALIZED`; abort coherently if the MPI implementation provides less.
- Do not call `fork()` after MPI initialization; every environment uses dedicated MPI ranks.
- Keep Smarties on its current CPU neural-network path; do not add PyTorch, CUDA, pybind11, or another Python runtime.
- Before every node3 configure, build, or test command, run `source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh` in the same shell.
- Require `gcc -dumpfullversion -dumpversion` and `g++ -dumpfullversion -dumpversion` to equal `8.5.0`.
- Require `mpicc --showme:command` to equal `/data2/mjwu/local/gcc-8.5.0/bin/gcc` and `mpicxx --showme:command` to equal `/data2/mjwu/local/gcc-8.5.0/bin/g++`.
- Use `/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0` as `IBAMR_ROOT` and its `lib64/cmake/ibamr/IBAMRConfig.cmake` package.
- Never reuse `/data2/mjwu/local/smarties/build-node3` for coupling verification; create a fresh revision-specific build directory.
- Local files are the source of truth. Upload immutable snapshots to `/data2/mjwu/local/coupling-src/`; never make an unreturned node3-only source change.
- Keep raw logs and partial conclusions under `.artifacts/ibamr-smarties-investigations/`; write nothing to `experience/verified/` unless every admission gate passes.

---

### Task 1: Repository hygiene and coupling governance archive

**Files:**
- Modify: `.gitignore`
- Add: `.agents/skills/ibamr-smarties-coupling/SKILL.md`
- Add: `.agents/skills/ibamr-smarties-coupling/agents/openai.yaml`
- Add: `.agents/skills/ibamr-smarties-coupling/references/architecture-contract.md`
- Add: `.agents/skills/ibamr-smarties-coupling/references/experience-admission.md`
- Add: `experience/README.md`
- Add: `experience/verified/README.md`
- Add: `experience/node3_smarties_uv_install.md`
- Add: `experience/smarties_api_ibamr_coupling_research.md`

**Interfaces:**
- Consumes: the approved architecture skill and existing local research files.
- Produces: tracked governance rules and ignore boundaries used by every later task.

- [ ] **Step 1: Add exact transient-data ignores**

Append these entries to `.gitignore`:

```gitignore
/.artifacts/
/.codebase-memory/
/.worktrees/
/couplings/ibamr/build/
/couplings/ibamr/runs/
```

- [ ] **Step 2: Verify only transient paths are ignored**

Run:

```powershell
git check-ignore .artifacts/probe.log .codebase-memory/graph.db.zst .worktrees/probe couplings/ibamr/build/probe couplings/ibamr/runs/probe
git check-ignore couplings/ibamr/core/MpiSession.cpp
```

Expected: the first command prints five paths; the second prints nothing and exits nonzero.

- [ ] **Step 3: Stage governance files explicitly**

Run:

```powershell
git add .gitignore .agents/skills/ibamr-smarties-coupling experience/README.md experience/verified/README.md experience/node3_smarties_uv_install.md experience/smarties_api_ibamr_coupling_research.md
git diff --cached --check
```

Expected: no artifacts, codebase graph, tarball, build output, or run output is staged.

- [ ] **Step 4: Commit**

```powershell
git commit -m "docs: archive IBAMR coupling governance"
```

### Task 2: Local immutable packaging workflow

**Files:**
- Create: `couplings/ibamr/scripts/package_local.ps1`
- Create: `couplings/ibamr/tests/test_package_local.ps1`

**Interfaces:**
- Consumes: Git working-tree file list and `.gitignore` rules from Task 1.
- Produces: a caller-selected output directory containing a `.tar.gz` and a `.sha256` manifest without `.git`, `.artifacts`, `.codebase-memory`, build, or run data.

- [ ] **Step 1: Write the failing behavioral test**

The test must invoke the real packaging script against the current repository, list the resulting archive, and assert consumer-visible contents:

```powershell
$repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$out = Join-Path $repo '.artifacts\package-test'
& "$repo\couplings\ibamr\scripts\package_local.ps1" -Repository $repo -OutputDirectory $out
if ($LASTEXITCODE -ne 0) { throw 'package_local.ps1 failed' }
$archive = Get-ChildItem $out -Filter '*.tar.gz' | Select-Object -First 1
if ($null -eq $archive) { throw 'archive missing' }
$listing = & tar -tzf $archive.FullName
if ($listing -notcontains 'docs/superpowers/specs/2026-08-04-ibamr-eel2d-coupling-framework-design.md') { throw 'tracked design missing' }
foreach ($forbidden in @('.git/', '.artifacts/', '.codebase-memory/', 'couplings/ibamr/build/', 'couplings/ibamr/runs/')) {
    if ($listing | Where-Object { $_.StartsWith($forbidden) }) { throw "forbidden path packaged: $forbidden" }
}
```

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File couplings/ibamr/tests/test_package_local.ps1
```

Expected: FAIL because `package_local.ps1` does not exist.

- [ ] **Step 3: Implement the minimal packaging script**

Implement these behaviors:

```powershell
param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$git = 'C:\Program Files\Git\cmd\git.exe'
$revision = (& $git -C $Repository rev-parse --short=12 HEAD).Trim()
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$name = "smarties-ibamr-$stamp-$revision"
$stage = Join-Path $OutputDirectory $name
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$files = & $git -C $Repository ls-files --cached --others --exclude-standard
foreach ($relative in $files) {
    $source = Join-Path $Repository $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
    $target = Join-Path $stage $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}
$manifest = Join-Path $stage 'SOURCE_MANIFEST.sha256'
Get-ChildItem $stage -Recurse -File | Where-Object FullName -ne $manifest | ForEach-Object {
    $hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
    $relative = $_.FullName.Substring($stage.Length + 1).Replace('\','/')
    "$hash  $relative"
} | Set-Content -Encoding ascii $manifest
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
& tar -czf (Join-Path $OutputDirectory "$name.tar.gz") -C $stage .
```

- [ ] **Step 4: Run GREEN and mutation check**

Run the test, then temporarily alter the exclusion by passing an ignored probe through `git ls-files`; confirm the test would fail if `.artifacts/` entered the archive. Restore the script and rerun:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File couplings/ibamr/tests/test_package_local.ps1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add couplings/ibamr/scripts/package_local.ps1 couplings/ibamr/tests/test_package_local.ps1
git commit -m "build: add local coupling snapshot packaging"
```

### Task 3: Smarties borrowed-MPI ownership

**Files:**
- Modify: `source/smarties/Settings/ExecutionInfo.h`
- Modify: `source/smarties/Settings/ExecutionInfo.cpp`
- Modify: `CMakeLists.txt`
- Create: `couplings/ibamr/CMakeLists.txt`
- Create: `couplings/ibamr/tests/CMakeLists.txt`
- Create: `couplings/ibamr/tests/test_borrowed_engine_shutdown.cpp`
- Create: `couplings/ibamr/tests/test_owned_engine_shutdown.cpp`

**Interfaces:**
- Consumes: `smarties::Engine(MPI_Comm, int, char**)` and `libsmarties`.
- Produces: `ExecutionInfo::bOwnMPI`; embedded destruction leaves MPI active, standalone destruction finalizes MPI.

- [ ] **Step 1: Write the borrowed-MPI failing test**

```cpp
#include <smarties/Engine.h>
#include <mpi.h>

int main(int argc, char** argv)
{
    int provided = MPI_THREAD_SINGLE;
    MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
    if (provided < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 90);
    {
        smarties::Engine engine(MPI_COMM_WORLD, argc, argv);
    }
    int finalized = 0;
    MPI_Finalized(&finalized);
    if (finalized) return 1;
    MPI_Finalize();
    return 0;
}
```

Register it as `borrowed_engine_shutdown` and run it with one MPI rank.

- [ ] **Step 2: Write the standalone ownership characterization test**

```cpp
#include <smarties/Engine.h>
#include <mpi.h>

int main(int argc, char** argv)
{
    {
        smarties::Engine engine(argc, argv);
    }
    int finalized = 0;
    MPI_Finalized(&finalized);
    return finalized ? 0 : 1;
}
```

Register it as `owned_engine_shutdown` and run it as a standalone executable, not inside an already initialized MPI process.

- [ ] **Step 3: Package and upload the RED snapshot**

Run locally:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File couplings/ibamr/scripts/package_local.ps1 -Repository (Get-Location).Path -OutputDirectory .artifacts/packages
```

Upload the newest archive to `/data2/mjwu/local/coupling-src/incoming/`, extract it into a new timestamped directory, and never overwrite a previous snapshot.

- [ ] **Step 4: Configure and run RED on node3**

Every node3 shell starts with:

```bash
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
test "$(gcc -dumpfullversion -dumpversion)" = "8.5.0"
test "$(g++ -dumpfullversion -dumpversion)" = "8.5.0"
test "$(mpicc --showme:command)" = "/data2/mjwu/local/gcc-8.5.0/bin/gcc"
test "$(mpicxx --showme:command)" = "/data2/mjwu/local/gcc-8.5.0/bin/g++"
```

Configure with a new build directory:

```bash
COUPLING_SRC=$(find /data2/mjwu/local/coupling-src -mindepth 1 -maxdepth 1 -type d -name 'smarties-ibamr-*' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
COUPLING_BUILD=/data2/mjwu/local/coupling-build/$(basename "$COUPLING_SRC")
cmake -S "$COUPLING_SRC" -B "$COUPLING_BUILD" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=/data2/mjwu/local/openmpi/bin/mpicc \
  -DCMAKE_CXX_COMPILER=/data2/mjwu/local/openmpi/bin/mpicxx \
  -DCOMPILE_PY_SO=OFF \
  -DBUILD_IBAMR_COUPLING=OFF \
  -DBUILD_IBAMR_COUPLING_TESTS=ON
cmake --build "$COUPLING_BUILD" --target borrowed_engine_shutdown owned_engine_shutdown -j4
ctest --test-dir "$COUPLING_BUILD" -R borrowed_engine_shutdown --output-on-failure
```

Expected: `borrowed_engine_shutdown` FAILS because current `ExecutionInfo::~ExecutionInfo()` finalizes MPI. Run `owned_engine_shutdown` separately and expect PASS, proving the regression guard is valid.

- [ ] **Step 5: Implement minimal ownership state**

Add to `ExecutionInfo`:

```cpp
const bool bOwnMPI;
```

Initialize it before existing fields:

```cpp
ExecutionInfo::ExecutionInfo(const std::vector<std::string>& args) : bOwnMPI(true), bOwnArgv(true)
ExecutionInfo::ExecutionInfo(int argc, char** argv) : bOwnMPI(true), bOwnArgv(false), argc(argc), argv(argv)
ExecutionInfo::ExecutionInfo(const MPI_Comm& world, int argc, char** argv) : bOwnMPI(false), bOwnArgv(false), argc(argc), argv(argv)
```

Only extend the initializer lists; keep the existing constructor bodies unchanged.

Change only the finalization line:

```cpp
if (bOwnMPI) MPI_Finalize();
```

- [ ] **Step 6: Run GREEN on a fresh node3 snapshot**

Repackage locally, upload to a new immutable directory, rebuild in a new directory, and run:

```bash
ctest --test-dir "$COUPLING_BUILD" -R 'borrowed_engine_shutdown|owned_engine_shutdown' --output-on-failure
```

Expected: 2/2 PASS.

- [ ] **Step 7: Commit**

```powershell
git add CMakeLists.txt source/smarties/Settings/ExecutionInfo.h source/smarties/Settings/ExecutionInfo.cpp couplings/ibamr/CMakeLists.txt couplings/ibamr/tests/CMakeLists.txt couplings/ibamr/tests/test_borrowed_engine_shutdown.cpp couplings/ibamr/tests/test_owned_engine_shutdown.cpp
git commit -m "fix: preserve MPI ownership for embedded engines"
```

### Task 4: Driver-owned MPI session and communicator validation

**Files:**
- Create: `couplings/ibamr/core/MpiSession.h`
- Create: `couplings/ibamr/core/MpiSession.cpp`
- Create: `couplings/ibamr/core/CommunicatorLayout.h`
- Create: `couplings/ibamr/core/CommunicatorLayout.cpp`
- Create: `couplings/ibamr/tests/test_mpi_session.cpp`
- Create: `couplings/ibamr/tests/test_communicator_layout.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `MpiSession(int&, char**&)`, `~MpiSession()`, `MPI_Comm world() const`; `CommunicatorLayout(MPI_Comm)`, `rank()`, `size()`, `valid()`.

- [ ] **Step 1: Write RED tests using real MPI**

`test_mpi_session.cpp` must assert MPI is initialized inside the object and not finalized until destruction. `test_communicator_layout.cpp`, run with two ranks, must split `MPI_COMM_WORLD` by `world_rank % 2`, construct a layout over the resulting communicator, and assert literal size `1` and rank `0` on both colors.

- [ ] **Step 2: Run RED on node3**

```bash
ctest --test-dir "$COUPLING_BUILD" -R 'mpi_session|communicator_layout' --output-on-failure
```

Expected: build or link failure because both classes are absent.

- [ ] **Step 3: Implement `MpiSession`**

Use the exact lifecycle:

```cpp
MpiSession::MpiSession(int& argc, char**& argv)
{
    int initialized = 0;
    MPI_Initialized(&initialized);
    if (initialized) throw std::runtime_error("MpiSession requires ownership before MPI initialization");
    MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided_);
    if (provided_ < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 91);
}

MpiSession::~MpiSession()
{
    int finalized = 0;
    MPI_Finalized(&finalized);
    if (!finalized) MPI_Finalize();
}
```

The class is non-copyable and non-movable.

- [ ] **Step 4: Implement `CommunicatorLayout` without ownership**

Store the communicator handle without duplicating or freeing it, query rank/size at construction, and throw on `MPI_COMM_NULL`. Do not add a destructor that calls `MPI_Comm_free`.

- [ ] **Step 5: Run GREEN and mutate the validation**

Run both tests. Temporarily remove the `MPI_COMM_NULL` check and confirm a dedicated null-communicator test fails or aborts; restore the check and rerun all four MPI tests from Tasks 3 and 4.

- [ ] **Step 6: Commit**

```powershell
git add couplings/ibamr/core couplings/ibamr/tests couplings/ibamr/CMakeLists.txt
git commit -m "feat: add driver-owned MPI coupling core"
```

### Task 5: Fidelity input rendering and curriculum files

**Files:**
- Create: `couplings/ibamr/cases/eel2d/upstream/input2d.in`
- Create: `couplings/ibamr/configs/fidelity/coarse.conf`
- Create: `couplings/ibamr/configs/fidelity/medium.conf`
- Create: `couplings/ibamr/configs/fidelity/fine.conf`
- Create: `couplings/ibamr/scripts/render_input.cmake`
- Create: `couplings/ibamr/tests/test_render_input.cmake`

**Interfaces:**
- Produces: `cmake -DFIDELITY_FILE=... -DOUTPUT_FILE=... -P render_input.cmake` and a concrete IBAMR `input2d`.

- [ ] **Step 1: Write the RED CMake-script test**

The test renders all three configurations into a temporary directory and reads the outputs. Assert these literal tuples:

```text
coarse: N = 32, MAX_LEVELS = 2, REF_RATIO = 4
medium: N = 64, MAX_LEVELS = 3, REF_RATIO = 4
fine: N = 128, MAX_LEVELS = 3, REF_RATIO = 4
```

It must also assert that the tracked `input2d.in` hash is unchanged before and after rendering.

- [ ] **Step 2: Run RED locally**

```powershell
cmake -P couplings/ibamr/tests/test_render_input.cmake
```

Expected: FAIL because the renderer and configs do not exist.

- [ ] **Step 3: Implement literal fidelity files and renderer**

Each `.conf` sets `EEL_N`, `EEL_MAX_LEVELS`, and `EEL_REF_RATIO`. The renderer includes the selected file, validates positive integer values, and calls:

```cmake
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/../cases/eel2d/upstream/input2d.in"
  "${OUTPUT_FILE}"
  @ONLY)
```

- [ ] **Step 4: Run GREEN**

Run the CMake test locally and on node3. Expected: both PASS and the source template hash remains unchanged.

- [ ] **Step 5: Commit**

```powershell
git add couplings/ibamr/cases/eel2d/upstream/input2d.in couplings/ibamr/configs/fidelity couplings/ibamr/scripts/render_input.cmake couplings/ibamr/tests/test_render_input.cmake
git commit -m "feat: add reproducible eel2d fidelity inputs"
```

### Task 6: Pin the IBAMR eel2d source snapshot and link target

**Files:**
- Create: `couplings/ibamr/cases/eel2d/upstream/PROVENANCE.md`
- Create: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.h`
- Create: `couplings/ibamr/cases/eel2d/upstream/IBEELKinematics.cpp`
- Create: `couplings/ibamr/cases/eel2d/upstream/eel2d.vertex`
- Modify: `CMakeLists.txt`
- Modify: `couplings/ibamr/CMakeLists.txt`

**Interfaces:**
- Consumes: local IBAMR files under `C:/Users/wumj/Project/IBAMR/examples/ConstraintIB/eel2d/` and `IBAMR::IBAMR2d` on node3.
- Produces: option `BUILD_IBAMR_COUPLING`, target `ibamr_eel2d_support`, and pinned source hashes.

- [ ] **Step 1: Copy exact upstream files locally**

Use filesystem copies from the local IBAMR tree. Do not edit the source files while copying. Record SHA-256 for all four files in `PROVENANCE.md`, together with source path, IBAMR 0.18.0, and the IBAMR 3-clause BSD license reference.

- [ ] **Step 2: Add opt-in CMake integration**

At the Smarties root:

```cmake
option(BUILD_IBAMR_COUPLING "Build the IBAMR coupling integration" OFF)
option(BUILD_IBAMR_COUPLING_TESTS "Build coupling ownership tests" OFF)
if(BUILD_IBAMR_COUPLING OR BUILD_IBAMR_COUPLING_TESTS)
  add_subdirectory(couplings/ibamr)
endif()
```

In the coupling CMake file:

```cmake
if(BUILD_IBAMR_COUPLING)
  find_package(IBAMR CONFIG REQUIRED
    PATHS "$ENV{IBAMR_ROOT}/lib64/cmake/ibamr"
    NO_DEFAULT_PATH)
  add_library(ibamr_eel2d_support STATIC
    cases/eel2d/upstream/IBEELKinematics.cpp)
  target_include_directories(ibamr_eel2d_support PUBLIC cases/eel2d/upstream)
  target_link_libraries(ibamr_eel2d_support PUBLIC IBAMR::IBAMR2d)
endif()
```

- [ ] **Step 3: Run the first node3 configure/link check**

```bash
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
cmake -S "$COUPLING_SRC" -B "$COUPLING_BUILD" \
  -DCMAKE_C_COMPILER=/data2/mjwu/local/openmpi/bin/mpicc \
  -DCMAKE_CXX_COMPILER=/data2/mjwu/local/openmpi/bin/mpicxx \
  -DCOMPILE_PY_SO=OFF \
  -DBUILD_IBAMR_COUPLING=ON \
  -DIBAMR_DIR="$IBAMR_ROOT/lib64/cmake/ibamr"
cmake --build "$COUPLING_BUILD" --target ibamr_eel2d_support -j4
```

Expected: GCC 8.5.0 compiles the pinned kinematics file and links the static support target against `IBAMR::IBAMR2d`.

- [ ] **Step 4: Commit**

```powershell
git add CMakeLists.txt couplings/ibamr/CMakeLists.txt couplings/ibamr/cases/eel2d/upstream
git commit -m "build: pin and link the IBAMR eel2d source"
```

### Task 7: Extract the eel2d lifecycle into `EelEnvironment`

**Files:**
- Create: `couplings/ibamr/cases/eel2d/EelEnvironment.h`
- Create: `couplings/ibamr/cases/eel2d/EelEnvironment.cpp`
- Create: `couplings/ibamr/tests/test_eel_environment_smoke.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`
- Modify: `couplings/ibamr/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `initialize(MPI_Comm, const std::string&)`, `advanceOneStep()`, `stepsRemaining() const`, and `shutdown()`.

- [ ] **Step 1: Write the RED integration test**

The real IBAMR test initializes an environment on `MPI_COMM_WORLD` with a rendered coarse input, advances exactly one step, calls `shutdown()`, and then asserts:

```cpp
int finalized = 0;
MPI_Finalized(&finalized);
if (finalized) return 3;
```

Run with one rank and a timeout of 180 seconds. The production change caught is premature MPI finalization or failure to destroy IBAMR resources before returning.

- [ ] **Step 2: Run RED on node3**

Expected: compile failure because `EelEnvironment` is absent.

- [ ] **Step 3: Define the exact public class**

```cpp
class EelEnvironment
{
public:
    EelEnvironment();
    ~EelEnvironment();
    EelEnvironment(const EelEnvironment&) = delete;
    EelEnvironment& operator=(const EelEnvironment&) = delete;
    void initialize(MPI_Comm environment_comm, const std::string& input_file);
    void advanceOneStep();
    bool stepsRemaining() const;
    void shutdown();
private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
```

- [ ] **Step 4: Move the original eel2d lifecycle into `Impl`**

Use `examples/ConstraintIB/eel2d/example.cpp:68-421` as the behavior source. Make these exact structural changes:

1. Replace `main()` and `MPI_COMM_WORLD` ownership with `initialize(environment_comm, input_file)`.
2. Assign `PETSC_COMM_WORLD = environment_comm` before constructing `IBTKInit`.
3. Store the original initialization objects needed after setup as `Impl` members.
4. Move one body of the original time loop into `advanceOneStep()` without changing numerical expressions.
5. Make `stepsRemaining()` reflect both end-time comparison and the integrator's `stepsRemaining()`.
6. Move cleanup after the loop into idempotent `shutdown()` and call it from the destructor.
7. Keep visualization, restart, timer, and postprocessing writes controlled by the rendered input.

- [ ] **Step 5: Run GREEN with real IBAMR**

```bash
ctest --test-dir "$COUPLING_BUILD" -R eel_environment_smoke --output-on-failure --timeout 180
```

Expected: one coarse step completes, resources shut down, and MPI remains active for the outer test.

- [ ] **Step 6: Repeat three times before refactoring**

Run the same test three separate times. A one-off pass does not permit refactoring or experience admission.

- [ ] **Step 7: Commit**

```powershell
git add couplings/ibamr/cases/eel2d/EelEnvironment.* couplings/ibamr/tests/test_eel_environment_smoke.cpp couplings/ibamr/CMakeLists.txt couplings/ibamr/tests/CMakeLists.txt
git commit -m "feat: encapsulate the eel2d simulation lifecycle"
```

### Task 8: Smarties smoke adapter and Coupling Driver

**Files:**
- Create: `couplings/ibamr/core/CouplingDriver.h`
- Create: `couplings/ibamr/core/CouplingDriver.cpp`
- Create: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.h`
- Create: `couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp`
- Create: `couplings/ibamr/cases/eel2d/main.cpp`
- Create: `couplings/ibamr/configs/training/smoke.json`
- Create: `couplings/ibamr/tests/test_eel_smoke_protocol.cpp`
- Modify: `couplings/ibamr/CMakeLists.txt`

**Interfaces:**
- Consumes: `MpiSession`, external-communicator `smarties::Engine`, callback `MPI_Comm`, and `EelEnvironment`.
- Produces: executable `ibamr_eel2d_smoke` and a lifecycle-only Smarties protocol.

- [ ] **Step 1: Write the RED protocol test**

Use the real Smarties `Communicator` boundary with a short run and assert external outcomes: process exit code zero, a terminal transition after the configured smoke step count, and MPI finalization only after `CouplingDriver` returns. Do not assert calls on a mock communicator.

- [ ] **Step 2: Implement the adapter contract**

The callback must execute this exact protocol:

```cpp
comm->setStateActionDims(1, 1);
comm->setActionScales({1.0}, {-1.0}, true);
environment.initialize(environment_comm, input_file);
comm->sendInitState({0.0});
for (unsigned step = 0; step < smoke_steps && environment.stepsRemaining(); ++step) {
    const std::vector<double> action = comm->recvAction();
    if (action.size() != 1) MPI_Abort(environment_comm, 92);
    environment.advanceOneStep();
    const double normalized_time = static_cast<double>(step + 1) / smoke_steps;
    const bool terminal = step + 1 == smoke_steps || !environment.stepsRemaining();
    if (terminal) comm->sendTermState({normalized_time}, 0.0);
    else comm->sendState({normalized_time}, 0.0);
    if (comm->terminateTraining()) break;
}
environment.shutdown();
```

The action is deliberately ignored after shape validation. Document that reward zero and normalized time are lifecycle probes, not an RL formulation.

- [ ] **Step 3: Implement the driver entry point**

```cpp
int main(int argc, char** argv)
{
    ibamr_smarties::MpiSession mpi(argc, argv);
    smarties::Engine engine(mpi.world(), argc, argv);
    if (engine.parse()) return 2;
    engine.run(ibamr_smarties::eel2d::runSmokeEpisode);
    return 0;
}
```

- [ ] **Step 4: Run RED then GREEN on node3**

First run the test before implementation and record the expected missing-symbol failure. After implementation:

```bash
ctest --test-dir "$COUPLING_BUILD" -R eel_smoke_protocol --output-on-failure --timeout 300
```

Expected: PASS with no `MPI_Finalize` from Smarties and no hang after callback return.

- [ ] **Step 5: Commit**

```powershell
git add couplings/ibamr/core/CouplingDriver.* couplings/ibamr/cases/eel2d/EelSmartiesAdapter.* couplings/ibamr/cases/eel2d/main.cpp couplings/ibamr/configs/training/smoke.json couplings/ibamr/tests/test_eel_smoke_protocol.cpp couplings/ibamr/CMakeLists.txt
git commit -m "feat: run eel2d through the Smarties smoke protocol"
```

### Task 9: node3 build and one-command run scripts

**Files:**
- Create: `couplings/ibamr/scripts/build_node3.sh`
- Create: `couplings/ibamr/scripts/run_node3.sh`
- Create: `couplings/ibamr/tests/test_node3_scripts.sh`
- Create: `couplings/ibamr/README.md`

**Interfaces:**
- Produces: `build_node3.sh --source --build` and `run_node3.sh smoke --envs --ranks-per-env --fidelity --training --smoke-steps`; `train` exits nonzero with an explicit unsupported message.

- [ ] **Step 1: Write the RED shell test**

Run the real scripts in `--dry-run` mode. Assert exit status and derived command for these literal cases:

```text
smoke --envs 1 --ranks-per-env 1 -> accepted
smoke --envs 2 --ranks-per-env 2 -> accepted and emits four environment ranks plus configured learner ranks
smoke --envs 0 -> rejected
smoke --ranks-per-env 0 -> rejected
train -> rejected with exit 64
GCC 8.4.0 fixture -> rejected before CMake
```

- [ ] **Step 2: Run RED locally and on node3**

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
```

Expected: FAIL because scripts are absent.

- [ ] **Step 3: Implement strict environment preflight**

Both scripts must source the verified environment and execute:

```bash
ENV_SCRIPT=/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
source "$ENV_SCRIPT"
[[ "$(gcc -dumpfullversion -dumpversion)" == "8.5.0" ]]
[[ "$(g++ -dumpfullversion -dumpversion)" == "8.5.0" ]]
[[ "$(mpicc --showme:command)" == "/data2/mjwu/local/gcc-8.5.0/bin/gcc" ]]
[[ "$(mpicxx --showme:command)" == "/data2/mjwu/local/gcc-8.5.0/bin/g++" ]]
[[ "$IBAMR_ROOT" == "/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0" ]]
```

Any failed predicate exits before configuring or launching.

- [ ] **Step 4: Implement revision-specific build and run directories**

For a snapshot named by `$SNAPSHOT_NAME`, build paths are `/data2/mjwu/local/coupling-build/$SNAPSHOT_NAME/`. The run script derives `$RUN_ID` with `date -u +%Y%m%dT%H%M%SZ` plus the Git revision and writes to `$COUPLING_SRC/couplings/ibamr/runs/$RUN_ID/`. It renders input into the run directory, copies training JSON, writes a manifest, and preserves the application exit code.

- [ ] **Step 5: Implement stable CLI and curriculum mapping**

`--fidelity coarse|medium|fine|curriculum` maps to the tracked configs. Curriculum emits Smarties `--appSettings` and `--nStepPappSett` lists; phase one smoke tests invoke single fidelity. `train` always exits 64 until a later approved RL spec implements it.

- [ ] **Step 6: Run GREEN**

Run `bash -n` on both scripts, the shell behavioral test, and one real `--dry-run` after sourcing the node3 environment.

- [ ] **Step 7: Commit**

```powershell
git add couplings/ibamr/scripts/build_node3.sh couplings/ibamr/scripts/run_node3.sh couplings/ibamr/tests/test_node3_scripts.sh couplings/ibamr/README.md
git commit -m "build: add reproducible node3 eel2d workflow"
```

### Task 10: Execute the staged node3 verification matrix

**Files:**
- Create locally during runs: `.artifacts/ibamr-smarties-investigations/eel2d-stage1/`, with one downloaded subdirectory per node3 manifest run ID.
- Modify only if evidence supports it: `experience/README.md`
- Create only if every gate passes: `experience/verified/2026-08-04-eel2d-stage1-lifecycle.md`

**Interfaces:**
- Consumes: immutable local snapshot and all automated tests.
- Produces: build logs, manifests, exit codes, repeat-run evidence, and an admission decision.

- [ ] **Step 1: Package and upload the final candidate**

Create a local package, upload it to `/data2/mjwu/local/coupling-src/incoming/`, verify the archive SHA-256 on both machines, and extract to a new immutable directory.

- [ ] **Step 2: Run the complete unit suite**

```bash
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
ctest --test-dir "$COUPLING_BUILD" --output-on-failure
```

Expected: ownership, MPI session, communicator layout, renderer, script, eel environment, and Smarties protocol tests all pass.

- [ ] **Step 3: Run topology matrix in order**

Run and archive each command separately:

```bash
./couplings/ibamr/scripts/run_node3.sh smoke --envs 1 --ranks-per-env 1 --fidelity coarse --smoke-steps 1 --training couplings/ibamr/configs/training/smoke.json
./couplings/ibamr/scripts/run_node3.sh smoke --envs 1 --ranks-per-env 2 --fidelity coarse --smoke-steps 1 --training couplings/ibamr/configs/training/smoke.json
./couplings/ibamr/scripts/run_node3.sh smoke --envs 2 --ranks-per-env 1 --fidelity coarse --smoke-steps 1 --training couplings/ibamr/configs/training/smoke.json
./couplings/ibamr/scripts/run_node3.sh smoke --envs 1 --ranks-per-env 1 --fidelity medium --smoke-steps 1 --training couplings/ibamr/configs/training/smoke.json
```

- [ ] **Step 4: Repeat each successful topology three times**

Store each manifest and exit code separately. Do not collapse repeated results into one log.

- [ ] **Step 5: Inject a controlled input failure**

Run with a missing fidelity file and verify nonzero coordinated exit, no rank left running, and no attempt by Smarties to finalize caller-owned MPI.

- [ ] **Step 6: Download all evidence locally**

Download node3 run directories into `.artifacts/ibamr-smarties-investigations/eel2d-stage1/`. Compare manifest revisions and SHA-256 values against the local package.

- [ ] **Step 7: Apply the experience admission gate**

If any topology, repeat, failure path, artifact match, or independent review is missing, leave the issue open under artifacts and do not create a verified record. If all admission questions are yes, write one narrow lifecycle record and explicitly state that no meaningful fish control or reward was tested.

- [ ] **Step 8: Final documentation commit**

```powershell
git add couplings/ibamr/README.md
git add experience/README.md
if (Test-Path experience/verified/2026-08-04-eel2d-stage1-lifecycle.md) {
    git add experience/verified/2026-08-04-eel2d-stage1-lifecycle.md
}
git commit -m "docs: record verified eel2d lifecycle results"
```

Only add the verified file path if it exists after the gate; otherwise commit README corrections alone or make no documentation commit.

### Task 11: Final review and remote handoff

**Files:**
- Review: all files changed since commit `8c34dfc`

**Interfaces:**
- Produces: reviewable feature branch ready for optional push to `origin/feature/ibamr-eel2d-coupling`.

- [ ] **Step 1: Run final local checks**

```powershell
git diff --check 8c34dfc..HEAD
git status --short
powershell -NoProfile -ExecutionPolicy Bypass -File couplings/ibamr/tests/test_package_local.ps1
cmake -P couplings/ibamr/tests/test_render_input.cmake
```

- [ ] **Step 2: Verify node3 evidence is current**

Require the final tested revision in every node3 manifest to equal `git rev-parse HEAD`. Older successful runs do not verify newer code.

- [ ] **Step 3: Review scope**

Confirm no PyTorch/CUDA/pybind11 change, no post-MPI fork, no automatic `train` behavior, no server-only source, and no unverified experience admission.

- [ ] **Step 4: Push only after user authorization**

With temporary Clash proxy variables, push the feature branch:

```powershell
$env:HTTP_PROXY='http://127.0.0.1:7897'
$env:HTTPS_PROXY='http://127.0.0.1:7897'
$env:ALL_PROXY='http://127.0.0.1:7897'
git push -u origin feature/ibamr-eel2d-coupling
```

Do not push from node3 and do not force-push.
