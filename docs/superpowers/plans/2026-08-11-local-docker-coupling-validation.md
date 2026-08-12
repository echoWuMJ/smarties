# Local Docker Coupling Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and validate Smarties revision `e01980e8e06a77a54071dc97ea029b5d80a49321` inside the existing local `ibamr` Docker container without modifying its `/root` IBAMR installation.

**Architecture:** Treat the container's IBAMR stack as an immutable dependency and keep the packaged source, out-of-source build, runs, and evidence below the existing `D:\dataset_ib` to `/home/data` mapping. Preserve driver-owned MPI, borrowed Smarties communicators, environment-only CFD initialization, CPU learning, inside-out normal shutdown, and coordinated `MPI_Abort` failure shutdown. Local results diagnose the node3 timeouts but do not replace node3-specific admission evidence.

**Tech Stack:** Windows PowerShell, Docker Desktop, Linux Bash, CMake/CTest, C++17, MPI, IBAMR/PETSc/SAMRAI/IBTK, Silo C API, SHA-256 manifests.

## Global Constraints

- The Docker container is exactly `ibamr`; host `D:\dataset_ib` maps to container `/home/data`.
- The code-under-test revision is exactly `e01980e8e06a77a54071dc97ea029b5d80a49321`; the archive SHA-256 is exactly `efee191bbf6348cb91a54e86c9f658e936b0a11e39a63a3edf46ae648bf66cbf`.
- Do not modify, reinstall, overwrite, or patch anything below `/root`.
- Do not delete or replace a pre-existing source, build, run, or evidence directory. Stop and report the exact path instead.
- Build out of source with `COMPILE_PY_SO=OFF`, `BUILD_IBAMR_COUPLING=ON`, and `BUILD_IBAMR_COUPLING_TESTS=ON`.
- Use at most two build jobs and run CTest serially with `-j1`; do not introduce additional environment MPI ranks or OpenMP parallelism.
- `CouplingDriver` alone owns `MPI_Init_thread()` and `MPI_Finalize()`; Smarties borrows its communicator; only environment ranks initialize PETSc/SAMRAI/IBTK/IBAMR.
- Keep the Smarties CPU learner. PyTorch, CUDA, pybind11, and Python bindings are out of scope.
- Preserve existing test timeouts. Do not rerun or relax a failed test until its original logs, load, topology, and process state are captured.
- Keep all raw and provisional results outside `experience/verified`.

## File and directory map

- Existing immutable host archive: `C:\Users\wumj\Project\smarties\.worktrees\eel2d-frequency-control\.artifacts\packages\smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz`
- Existing immutable Silo reader: `C:\Users\wumj\Project\IBAMR\.artifacts\stage2-upload\inspect_silo_points.c`
- Create host mirror root: `D:\dataset_ib\smarties-local\e01980e8e06a`
- Create container root: `/home/data/smarties-local/e01980e8e06a`
- Extract the flat archive to revision-specific source directory: `/home/data/smarties-local/e01980e8e06a/source`
- Build in: `/home/data/smarties-local/e01980e8e06a/build`
- Run in: `/home/data/smarties-local/e01980e8e06a/runs/<run-name>`
- Store authoritative local evidence in: `/home/data/smarties-local/e01980e8e06a/evidence`
- Mirror the final report to ignored repository path: `.artifacts/local-docker-validation/e01980e8e06a/local-docker-report.md`
- No production source file is created or modified by this plan.

---

### Task 1: Inventory the immutable Docker environment

**Files:**
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\container-inspect.json`
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\host-cpu.txt`
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\container-environment.txt`
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\dependency-candidates.txt`

**Interfaces:**
- Consumes: existing Docker Desktop container `ibamr` and immutable `/root` installation.
- Produces: exact container state, CPU inventory, dependency candidates, and a pass/fail compatibility boundary for Task 2.

- [ ] **Step 1: Verify the target container exists and is running**

Run in PowerShell:

```powershell
docker inspect ibamr --format '{{.Name}}|{{.State.Status}}|{{.Image}}|{{range .Mounts}}{{.Source}}=>{{.Destination}};{{end}}'
```

Expected: name `/ibamr`, state `running`, and a mount containing `D:\dataset_ib=>/home/data`. If any field differs, stop without starting, recreating, or modifying the container.

- [ ] **Step 2: Create only the new evidence directory and record host/container identity**

Run in PowerShell:

```powershell
$hostRoot = 'D:\dataset_ib\smarties-local\e01980e8e06a'
if (Test-Path $hostRoot) { throw "target already exists: $hostRoot" }
New-Item -ItemType Directory -Path "$hostRoot\evidence\environment" | Out-Null
docker inspect ibamr | Set-Content -Encoding utf8 "$hostRoot\evidence\environment\container-inspect.json"
Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed | Out-File -Encoding utf8 "$hostRoot\evidence\environment\host-cpu.txt"
Get-CimInstance Win32_ComputerSystem | Format-List TotalPhysicalMemory | Out-File -Append -Encoding utf8 "$hostRoot\evidence\environment\host-cpu.txt"
```

Expected: a new root with only the environment evidence files; no existing path is overwritten.

- [ ] **Step 3: Record container CPU, toolchain, MPI, disk, and mounted filesystem**

Run in PowerShell:

```powershell
$out = 'D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\container-environment.txt'
docker exec ibamr bash -lc 'set -e; date --iso-8601=seconds; uname -a; lscpu; lscpu -p=CPU,CORE,SOCKET,ONLINE; nproc --all; taskset --version; cmake --version; gcc --version; g++ --version; mpiexec --version; mpicc --showme 2>/dev/null || mpicc -show; mpicxx --showme 2>/dev/null || mpicxx -show; df -h /home/data /root; mount | grep " /home/data " || true' | Set-Content -Encoding utf8 $out
```

Expected: commands return zero and the file contains nonempty CPU, compiler, MPI, and disk-space sections.

- [ ] **Step 4: Discover IBAMR, PETSc, Silo, environment scripts, and SAMRAI source without changing `/root`**

Run in PowerShell:

```powershell
$out = 'D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment\dependency-candidates.txt'
docker exec ibamr bash -lc 'set -e; find /root -type f -path "*/cmake/ibamr/IBAMRConfig.cmake" -print; find /root -type f -path "*/cmake/ibamr/IBAMRConfigVersion.cmake" -print -exec grep -E "PACKAGE_VERSION|IBAMR_VERSION" {} \; || true; find /root -type f -name petscvariables -print; find /root -type f -name petscversion.h -print -exec grep -E "PETSC_VERSION_(MAJOR|MINOR|SUBMINOR)" {} \; || true; find /root -type f -name silo.h -print -exec grep -E "SILO_VERSION|DB_VERSION" {} \; || true; find /root -type f -name "libsilo.*" -print; find /root -type f -name enable.sh -print; find /root -type f -path "*/source/hierarchy/boxes/BinaryTree.C" -print' | Set-Content -Encoding utf8 $out
```

Expected: at least one IBAMR config, Silo header/library pair, and SAMRAI `BinaryTree.C` candidate. If there are zero or ambiguous compatible IBAMR candidates, stop and report the complete list rather than guessing.

- [ ] **Step 5: Checkpoint Task 1**

Run:

```powershell
Get-ChildItem -Recurse 'D:\dataset_ib\smarties-local\e01980e8e06a\evidence\environment' | Select-Object FullName,Length
```

Expected: four nonempty evidence files. Do not commit raw machine inventory to Git.

---

### Task 2: Stage and verify the exact immutable source package

**Files:**
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\archives\smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz`
- Create: `/home/data/smarties-local/e01980e8e06a/source/`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/source-verification.txt`

**Interfaces:**
- Consumes: Task 1 compatible container and the exact pre-existing archive.
- Produces: manifest-verified source tree used unchanged by every later task.

- [ ] **Step 1: Verify the original archive before copying**

Run in PowerShell:

```powershell
$archive = 'C:\Users\wumj\Project\smarties\.worktrees\eel2d-frequency-control\.artifacts\packages\smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz'
$expected = 'efee191bbf6348cb91a54e86c9f658e936b0a11e39a63a3edf46ae648bf66cbf'
$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "archive hash mismatch: $actual" }
```

Expected: no output and `$actual` equals the exact expected SHA-256.

- [ ] **Step 2: Copy through the existing mapped directory and rehash on both sides**

Run in PowerShell:

```powershell
$archiveDir = 'D:\dataset_ib\smarties-local\e01980e8e06a\archives'
New-Item -ItemType Directory -Path $archiveDir | Out-Null
$destination = "$archiveDir\smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz"
Copy-Item -LiteralPath $archive -Destination $destination
if ((Get-FileHash -Algorithm SHA256 $destination).Hash.ToLowerInvariant() -ne $expected) { throw 'mapped host archive hash mismatch' }
docker exec ibamr sha256sum /home/data/smarties-local/e01980e8e06a/archives/smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz
```

Expected: container SHA-256 is also `efee191bbf6348cb91a54e86c9f658e936b0a11e39a63a3edf46ae648bf66cbf`.

- [ ] **Step 3: Extract once into a new source parent**

Run:

```powershell
docker exec ibamr bash -lc 'set -euo pipefail; root=/home/data/smarties-local/e01980e8e06a; src=$root/source; test ! -e "$src"; mkdir "$src"; tar -xzf "$root/archives/smarties-ibamr-20260810T170906Z-e01980e8e06a.tar.gz" -C "$src"; test -f "$src/CMakeLists.txt"'
```

Expected: zero exit; the source directory did not pre-exist.

- [ ] **Step 4: Verify package metadata and every source manifest entry**

Run:

```powershell
docker exec ibamr bash -lc 'set -euo pipefail; src=/home/data/smarties-local/e01980e8e06a/source; out=/home/data/smarties-local/e01980e8e06a/evidence/source-verification.txt; { grep -Fx "revision=e01980e8e06a77a54071dc97ea029b5d80a49321" "$src/SOURCE_METADATA.txt"; grep -Fx "tracked_dirty=false" "$src/SOURCE_METADATA.txt"; grep -Fx "included_untracked_count=0" "$src/SOURCE_METADATA.txt"; cd "$src"; sha256sum -c SOURCE_MANIFEST.sha256; test "$(wc -l < SOURCE_MANIFEST.sha256)" -eq 355; } > "$out" 2>&1'
```

Expected: zero exit, 355 manifest entries report `OK`, and metadata identifies the exact clean revision.

- [ ] **Step 5: Checkpoint Task 2**

Run:

```powershell
docker exec ibamr bash -lc 'test ! -e /home/data/smarties-local/e01980e8e06a/source/lib/libsmarties.so && tail -n 5 /home/data/smarties-local/e01980e8e06a/evidence/source-verification.txt'
```

Expected: source-tree `libsmarties.so` is absent and the manifest tail contains only `OK` lines.

---

### Task 3: Resolve compatibility and perform the isolated build

**Files:**
- Consume: `/home/data/smarties-local/e01980e8e06a/evidence/resolved-environment.env`
- Preserve: `/home/data/smarties-local/e01980e8e06a/evidence/samrai-patch-check.txt`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/samrai-overlay-patch-check.txt`
- Create: `/home/data/smarties-local/e01980e8e06a/build/`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/configure.log`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/build.log`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/runtime-identity.txt`

**Interfaces:**
- Consumes: Task 1 dependency candidates, Task 2 verified source, and the admitted overlay from `2026-08-11-local-ibamr-samrai-overlay.md`.
- Produces: one clean release build whose executable and runtime Smarties library identities are fixed for Tasks 4 and 5.

- [ ] **Step 1: Verify the admitted overlay consumer interface**

Run inside the container:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
source "$root/evidence/resolved-environment.env"
expected_overlay=$root/deps/ibamr-samrai-subcomm-v1
test "$OVERLAY_ROOT" = "$expected_overlay"
case "$IBAMR_DIR" in "$OVERLAY_ROOT"/*) ;; *) exit 65 ;; esac
case "$SAMRAI_SOURCE_ROOT" in "$OVERLAY_ROOT"/*) ;; *) exit 65 ;; esac
test -f "$IBAMR_DIR/IBAMRConfig.cmake"
test -f "$OVERLAY_ROOT/PATCHED_SMARTIES_SAMRAI.sha256"
test "$CC" = /usr/bin/gcc
test "$CXX" = /usr/bin/g++
test "$CPU_SET" = 0,2
```

Expected: every IBAMR/SAMRAI consumer path is inside the exact overlay, and no original `/root` IBAMR/SAMRAI package is selected.

- [ ] **Step 2: Independently re-prove the overlay SAMRAI communicator patch**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
src=$root/source
source "$root/evidence/resolved-environment.env"
patch --batch --dry-run -R -d "$SAMRAI_SOURCE_ROOT" -p1 -i "$src/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$root/evidence/samrai-overlay-patch-check.txt" 2>&1
SAMRAI_SOURCE_ROOT=/root/autoibamr/tmp/unpack/IBSAMRAI2-2025.10.29 bash "$src/couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh" >> "$root/evidence/samrai-overlay-patch-check.txt" 2>&1
```

Expected: reverse dry-run proves the overlay source is patched; the repository
source test independently proves the patch transforms the immutable pristine
source into the expected implementation. Both exit zero. The earlier
root-install failure remains preserved as
`LOCAL_IBAMR_SAMRAI_PATCH_NOT_PROVEN`; it is not overwritten or reclassified.

- [ ] **Step 3: Configure a new release build with the local immutable dependency**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
src=$root/source
build=$root/build
test ! -e "$build"
source "$root/evidence/resolved-environment.env"
export SAMRAI_SOURCE_ROOT
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCOMPILE_PY_SO=OFF -DBUILD_IBAMR_COUPLING=ON -DBUILD_IBAMR_COUPLING_TESTS=ON -DIBAMR_DIR="$IBAMR_DIR" 2>&1 | tee "$root/evidence/configure.log"
```

Expected: zero exit and CMake reports MPI and IBAMR found; Python binding configuration is absent.

- [ ] **Step 4: Build with at most two jobs and preserve the true pipeline status**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
source "$root/evidence/resolved-environment.env"
taskset -c "$CPU_SET" cmake --build "$root/build" --parallel 2 2>&1 | tee "$root/evidence/build.log"
```

Expected: zero exit and required targets reach 100 percent.

- [ ] **Step 5: Verify the executable/runtime-library binding and source immutability**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
src=$root/source
build=$root/build
exe=$build/couplings/ibamr/ibamr_eel2d_smoke
lib=$build/lib/libsmarties.so
test -x "$exe"
test -f "$lib"
test ! -e "$src/lib/libsmarties.so"
{
  sha256sum "$exe" "$lib"
  readelf -d "$exe" | grep -E 'RPATH|RUNPATH'
  ldd "$exe"
  ctest --test-dir "$build" -N
} > "$root/evidence/runtime-identity.txt" 2>&1
grep -F "$lib" "$root/evidence/runtime-identity.txt"
grep -F 'Total Tests: 19' "$root/evidence/runtime-identity.txt"
```

Expected: `ldd` resolves the build-tree `libsmarties.so`, source remains unchanged, and exactly 19 tests are registered. Any other test count blocks the full-suite claim.

---

### Task 4: Run focused and complete serial validation

**Files:**
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/focused-ctest.log`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/full-ctest.log`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/test-process-boundary.txt`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/test-resource-snapshots.txt`

**Interfaces:**
- Consumes: Task 3 verified build.
- Produces: exact focused and 19-test results plus load/process boundaries; Task 5 runs only after complete success.

- [ ] **Step 1: Record the pre-test resource and residual-process boundary**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
{
  date --iso-8601=seconds
  uptime
  ps -eo pid,ppid,psr,pcpu,pmem,stat,comm,args --sort=-pcpu | head -n 30
  pgrep -ax ctest || true
  ps -eo pid,ppid,comm,args | grep -E 'frequency_response_probe|eel_control_protocol|eel_smoke_protocol' | grep -v grep || true
} | tee "$root/evidence/test-resource-snapshots.txt"
```

Expected: no matching test process before launch. If a matching process exists, stop and preserve the snapshot without killing it.

- [ ] **Step 2: Run the focused architecture, topology, layout, physical-guard, and failure tests serially**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
source "$root/evidence/resolved-environment.env"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
taskset -c "$CPU_SET" ctest --test-dir "$root/build" -j1 --output-on-failure -R '^(borrowed_engine_shutdown|borrowed_communicator_alias|mpi_session|communicator_layout|eel_layout_invariant|eel_layout_mismatch_guard|eel_smoke_failure_after_mpi)$' 2>&1 | tee "$root/evidence/focused-ctest.log"
```

Expected: 7/7 tests pass, including the exact MPI abort diagnostic wrapper. On failure, capture Step 4 immediately and stop.

- [ ] **Step 3: Run the one complete suite from test 1 through test 19**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
source "$root/evidence/resolved-environment.env"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
taskset -c "$CPU_SET" ctest --test-dir "$root/build" -j1 --output-on-failure 2>&1 | tee "$root/evidence/full-ctest.log"
```

Expected: `100% tests passed, 0 tests failed out of 19`. Existing per-test timeouts remain unchanged. Do not launch a second full suite if this command fails.

- [ ] **Step 4: Record the immediate terminal resource/process boundary**

Run immediately after the focused run on failure or after the full run on success:

```bash
root=/home/data/smarties-local/e01980e8e06a
build=$root/build
{
  date --iso-8601=seconds
  uptime
  ps -eo pid,ppid,psr,pcpu,pmem,stat,comm,args --sort=-pcpu | head -n 30
  pgrep -ax ctest || true
  for exe in "$build/couplings/ibamr/frequency_response_probe" "$build/couplings/ibamr/tests/eel_control_protocol" "$build/couplings/ibamr/tests/eel_smoke_protocol" "$build/couplings/ibamr/ibamr_eel2d_smoke"; do
    count=0
    for proc in /proc/[0-9]*; do
      target=$(readlink -f "$proc/exe" 2>/dev/null || true)
      if [ "$target" = "$exe" ]; then count=$((count + 1)); printf 'pid=%s exe=%s\n' "${proc##*/}" "$target"; fi
    done
    printf 'exact_executable_count=%s executable=%s\n' "$count" "$exe"
  done
} | tee -a "$root/evidence/test-resource-snapshots.txt" "$root/evidence/test-process-boundary.txt"
test "$(grep -c 'exact_executable_count=0 ' "$root/evidence/test-process-boundary.txt")" -eq 4
test "$(pgrep -xc ctest || true)" -eq 0
```

Expected: every exact process count is zero. A nonzero count blocks Task 5 and is not cleaned up without separate authorization.

---

### Task 5: Produce physical medium-grid and negative-guard evidence

**Files:**
- Create: `/home/data/smarties-local/e01980e8e06a/runs/medium-ratio-1/`
- Create: `/home/data/smarties-local/e01980e8e06a/runs/coarse-negative/`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/silo-reader/inspect_silo_points.c`
- Create: `/home/data/smarties-local/e01980e8e06a/evidence/physical-summary.txt`

**Interfaces:**
- Consumes: Task 4 19/19 result, verified build, configured test fixture, and existing Silo reader with SHA-256 `97a5f641419de528d343d2e2a851d965cf921e4f8eab2629c239a16bc3a88f8a`.
- Produces: one medium ratio-1 physical result, direct Silo point counts, one coarse mismatch rejection, and terminal process checks.

- [ ] **Step 1: Stage and verify the existing Silo reader**

Run in PowerShell:

```powershell
$reader = 'C:\Users\wumj\Project\IBAMR\.artifacts\stage2-upload\inspect_silo_points.c'
$expected = '97a5f641419de528d343d2e2a851d965cf921e4f8eab2629c239a16bc3a88f8a'
if ((Get-FileHash -Algorithm SHA256 $reader).Hash.ToLowerInvariant() -ne $expected) { throw 'Silo reader hash mismatch' }
$destination = 'D:\dataset_ib\smarties-local\e01980e8e06a\evidence\silo-reader'
New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Item -LiteralPath $reader -Destination "$destination\inspect_silo_points.c"
docker exec ibamr sha256sum /home/data/smarties-local/e01980e8e06a/evidence/silo-reader/inspect_silo_points.c
```

Expected: container hash equals the exact expected reader SHA-256.

- [ ] **Step 2: Freeze the medium input, vertex file, command, and binary hashes**

Run inside the container:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
fixture=$root/build/couplings/ibamr/tests/eel-environment-smoke
run=$root/runs/medium-ratio-1
test ! -e "$run"
mkdir -p "$run"
cp "$fixture/input2d" "$fixture/eel2d.vertex" "$run/"
grep -E '^[[:space:]]*(N|MAX_LEVELS|REF_RATIO)[[:space:]]*=' "$run/input2d" > "$run/grid-directives.txt"
grep -Eq 'N[[:space:]]*=[[:space:]]*64' "$run/grid-directives.txt"
grep -Eq 'MAX_LEVELS[[:space:]]*=[[:space:]]*3' "$run/grid-directives.txt"
grep -Eq 'REF_RATIO[[:space:]]*=[[:space:]]*4' "$run/grid-directives.txt"
sha256sum "$root/build/couplings/ibamr/frequency_response_probe" "$root/build/lib/libsmarties.so" "$run/input2d" "$run/eel2d.vertex" > "$run/runtime-hashes.txt"
```

Expected: medium grid is exactly `N=64`, `MAX_LEVELS=3`, `REF_RATIO=4` and all four identities are recorded.

- [ ] **Step 3: Run exactly one medium ratio-1 decision**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
run=$root/runs/medium-ratio-1
cd "$run"
source "$root/evidence/resolved-environment.env"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
printf 'taskset -c %s mpiexec -n 1 frequency_response_probe --input-file input2d --ratio 1.0 --decisions 1 --direction-x -0.991204416615555 --direction-y 0.132339731304763\n' "$CPU_SET" > command.txt
set +e
timeout 300s taskset -c "$CPU_SET" mpiexec -n 1 "$root/build/couplings/ibamr/frequency_response_probe" --input-file input2d --ratio 1.0 --decisions 1 --direction-x -0.991204416615555 --direction-y 0.132339731304763 > stdout.log 2>&1
status=$?
set -e
printf '%s\n' "$status" > exit-code.txt
test "$status" -eq 0
test "$(grep -c 'EEL_FREQUENCY_PROBE' stdout.log)" -eq 1
awk '
  /EEL_FREQUENCY_PROBE/ {
    found++
    for (i = 1; i <= NF; ++i) {
      split($i, pair, "=")
      if (length(pair[1]) && length(pair[2])) value[pair[1]] = pair[2]
    }
  }
  END {
    numeric = "^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$"
    split("ratio decisions ibamr_steps elapsed_time displacement_x displacement_y forward_displacement mean_forward_velocity phase_start phase_end", required, " ")
    if (found != 1) exit 1
    for (i in required) if (value[required[i]] !~ numeric) exit 2
    ratio_error = value["ratio"] - 1.0; if (ratio_error < 0) ratio_error = -ratio_error
    phase_error = (value["phase_end"] - value["phase_start"]) - 6.28 * value["ratio"] * value["elapsed_time"]
    if (phase_error < 0) phase_error = -phase_error
    if (value["decisions"] != 1 || value["ibamr_steps"] < 1 || value["elapsed_time"] <= 0 || ratio_error > 1e-12 || phase_error > 1e-10) exit 3
    printf "ratio_error=%.17g phase_error=%.17g decisions=%s ibamr_steps=%s elapsed_time=%s\n", ratio_error, phase_error, value["decisions"], value["ibamr_steps"], value["elapsed_time"]
  }
' stdout.log > medium-assertions.txt
```

Expected: exit zero and exactly one summary record. A failure stops the task after immediate process/load capture; do not rerun.

- [ ] **Step 4: Compile the reader against the discovered Silo installation and inspect cycles 0, 40, and 80**

Resolve the unique Silo header and library from Task 1, then run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
run=$root/runs/medium-ratio-1
reader=$root/evidence/silo-reader
source "$root/evidence/resolved-environment.env"
grep -F 'SET(IBAMR_SILO_VERSION "4.11")' "$IBAMR_DIR/IBAMRConfig.cmake"
silo_prefix=/root/autoibamr/packages/silo-4.11-bsd
silo_include=$silo_prefix/include
silo_library=$silo_prefix/lib/libsilo.a
test -f "$silo_include/silo.h"
test -f "$silo_library"
gcc -std=c99 -O2 -Wall -Wextra -I"$silo_include" "$reader/inspect_silo_points.c" "$silo_library" -lm -o "$reader/inspect_silo_points"
cd "$run"
"$reader/inspect_silo_points" viz_eel2d_Str/lag_data.cycle_000000/lag_data.proc_0000.silo viz_eel2d_Str/lag_data.cycle_000040/lag_data.proc_0000.silo viz_eel2d_Str/lag_data.cycle_000080/lag_data.proc_0000.silo > coordinate-summary.txt
test "$(grep -c 'nels=2932 unique=2932 max_multiplicity=1' coordinate-summary.txt)" -eq 3
```

Expected: all three cycles contain 2932 finite unique points and maximum multiplicity one. The reader uses the installed Silo 4.11 prefix that matches `IBAMR_SILO_VERSION` in the resolved IBAMR config; temporary build-tree headers and libraries are not candidates.

- [ ] **Step 5: Run the invalid coarse initialization exactly once**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
fixture=$root/build/couplings/ibamr/tests/eel-environment-smoke
run=$root/runs/coarse-negative
test ! -e "$run"
mkdir -p "$run"
cp "$fixture/input2d.coarse" "$run/"
cp "$fixture/eel2d.vertex" "$run/"
cd "$run"
source "$root/evidence/resolved-environment.env"
set +e
taskset -c "$CPU_SET" mpiexec -n 1 "$root/build/couplings/ibamr/tests/eel_environment_smoke" input2d.coarse > stdout.log 2>&1
status=$?
set -e
printf '%s\n' "$status" > exit-code.txt
test "$status" -ne 0
test "$(grep -c 'eel kinematics layout point count 76 does not match Lagrangian vertex count 2932' stdout.log)" -eq 1
test "$(grep -c 'EEL_CONTROL' stdout.log || true)" -eq 0
```

Expected: nonzero exit, the exact mismatch diagnostic once, and no control transition.

- [ ] **Step 6: Record immediate physical-run process boundaries and summary**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
build=$root/build
{
  date --iso-8601=seconds
  grep 'EEL_FREQUENCY_PROBE' "$root/runs/medium-ratio-1/stdout.log"
  cat "$root/runs/medium-ratio-1/coordinate-summary.txt"
  grep 'eel kinematics layout point count' "$root/runs/coarse-negative/stdout.log"
  for exe in "$build/couplings/ibamr/frequency_response_probe" "$build/couplings/ibamr/tests/eel_environment_smoke"; do
    count=0
    for proc in /proc/[0-9]*; do
      target=$(readlink -f "$proc/exe" 2>/dev/null || true)
      if [ "$target" = "$exe" ]; then count=$((count + 1)); printf 'pid=%s exe=%s\n' "${proc##*/}" "$target"; fi
    done
    printf 'exact_executable_count=%s executable=%s\n' "$count" "$exe"
  done
  pgrep -af 'mpiexec|prterun' || true
} | tee "$root/evidence/physical-summary.txt"
test "$(grep -c 'exact_executable_count=0 ' "$root/evidence/physical-summary.txt")" -eq 2
```

Expected: exact executable process counts are zero. Treat broad MPI launcher matches as observations and inspect their commands before classifying residue.

---

### Task 6: Audit the evidence and hand off the local-only conclusion

**Files:**
- Create: `.artifacts/local-docker-validation/e01980e8e06a/local-docker-report.md`
- Create: `D:\dataset_ib\smarties-local\e01980e8e06a\evidence\evidence-manifest.sha256`

**Interfaces:**
- Consumes: Tasks 1-5 evidence, or the first gated failure if execution stopped earlier.
- Produces: one auditable local result with explicit node3 limitations and no unsupported experience promotion.

- [ ] **Step 1: Hash every evidence file after all writers have stopped**

Run inside the container:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
find "$root/evidence" "$root/runs" -type f ! -name evidence-manifest.sha256 -print0 | sort -z | xargs -0 sha256sum > "$root/evidence/evidence-manifest.sha256"
sha256sum -c "$root/evidence/evidence-manifest.sha256"
```

Expected: every listed file reports `OK`; do not edit hashed evidence afterward.

- [ ] **Step 2: Write the local report with exact claims and limitations**

The report must state:

```text
code revision: e01980e8e06a77a54071dc97ea029b5d80a49321
archive sha256: efee191bbf6348cb91a54e86c9f658e936b0a11e39a63a3edf46ae648bf66cbf
MPI owner: CouplingDriver
Smarties communicator: borrowed
CFD initialization: environment ranks only
learner backend: Smarties CPU
local container/image/toolchain identities: copied verbatim from Task 1
focused result: exact passed/total and duration
full CTest result: exact passed/total and duration
medium result: exact exit, summary record, and Silo counts, or gated reason
coarse guard result: exact exit and diagnostic, or gated reason
residual process result: exact-name counts and observation timestamp
claim boundary: local Docker functional evidence only; not node3 environment admission
experience status: not promoted
```

Expected: no statement upgrades inference to proven node3 root cause.

Create the report directory with `New-Item -ItemType Directory` and create the
report itself with `apply_patch`; do not use shell redirection to write the
repository-side report.

- [ ] **Step 3: Verify report completeness and repository cleanliness**

Run in PowerShell:

```powershell
$report = 'C:\Users\wumj\Project\smarties\.worktrees\eel2d-frequency-control\.artifacts\local-docker-validation\e01980e8e06a\local-docker-report.md'
$patterns = @('e01980e8e06a77a54071dc97ea029b5d80a49321','efee191bbf6348cb91a54e86c9f658e936b0a11e39a63a3edf46ae648bf66cbf','CouplingDriver','borrowed','Smarties CPU','not node3 environment admission','not promoted')
foreach ($pattern in $patterns) { if (-not (Select-String -LiteralPath $report -SimpleMatch $pattern)) { throw "report missing: $pattern" } }
git -C 'C:\Users\wumj\Project\smarties\.worktrees\eel2d-frequency-control' status --short
```

Expected: every pattern is present and tracked Git status is empty. Raw evidence and the report remain ignored.

- [ ] **Step 4: Final admission decision**

Report one of exactly these outcomes:

```text
LOCAL_PASS: all compatibility, build, 19/19, physical, Silo, guard, and process checks passed.
LOCAL_PARTIAL: build or focused checks passed but a later required gate failed; preserve the first failing evidence.
LOCAL_BLOCKED: container/dependency/SAMRAI-patch/source gate prevented a trustworthy build or run.
```

Expected: even `LOCAL_PASS` leaves node3 admission pending and creates no `experience/verified` entry.
