# Local IBAMR-SAMRAI Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a patched SAMRAI 2025.10.29 and IBAMR 0.18.0 overlay under the existing revision-specific `/home/data` validation root without modifying `/root`.

**Architecture:** Copy the immutable AutoIBAMR SAMRAI and IBAMR sources into an isolated overlay, apply the repository's communicator patch only to the SAMRAI copy, and build both packages with the container's existing GCC 10.2.1/OpenMPI 4.1.0 dependency stack. The overlay becomes the sole IBAMR dependency for the subsequent Smarties coupling build; driver-owned MPI, borrowed Smarties communicators, environment-only CFD initialization, CPU learning, inside-out shutdown, and fatal `MPI_Abort` remain unchanged.

**Tech Stack:** Docker Desktop, Bash, GNU patch, Autoconf Make, CMake 3.30.6, GCC/G++ 10.2.1 through OpenMPI 4.1.0 wrappers, SAMRAI 2025.10.29, IBAMR 0.18.0, PETSc 3.23.3, HDF5 1.12.2, libMesh 1.7.8, Silo 4.11.

## Global Constraints

- Treat all paths below `/root/autoibamr` as immutable read-only inputs.
- Create exactly one overlay at `/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1`; stop if it already exists.
- Keep copied sources, builds, installations, logs, and markers inside that overlay.
- Use the exact patch `/home/data/smarties-local/e01980e8e06a/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch` from revision `e01980e8e06a77a54071dc97ea029b5d80a49321`.
- Use container-visible logical CPUs `0,2`, which Task 1 proved belong to different physical cores; use no more than two parallel build jobs.
- Use `/usr/bin/mpicc`, `/usr/bin/mpicxx`, and `/usr/bin/mpif90`, with the existing AutoIBAMR environment sourced first.
- Reuse `/root/autoibamr/packages` only for HDF5, PETSc/HYPRE, libMesh, and Silo; replace only SAMRAI and IBAMR with overlay installations.
- Do not fall back to `/root/autoibamr/packages/IBSAMRAI2-2025.10.29` or `/root/autoibamr/packages/IBAMR-0.18.0` after the overlay build starts.
- Do not modify coupling source, timeouts, MPI ownership, rank partitioning, learner backend, or failure behavior.
- Preserve every failed command's log and exit code. Do not delete or rebuild an overlay path after failure without a separately approved new path.
- Do not write into `experience/verified`.

## File and directory map

- Overlay root: `/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1`
- SAMRAI source copy: `src/IBSAMRAI2-2025.10.29`
- IBAMR source copy: `src/IBAMR-0.18.0`
- SAMRAI build: `build/samrai`
- IBAMR build: `build/ibamr`
- SAMRAI install: `packages/IBSAMRAI2-2025.10.29`
- IBAMR install: `packages/IBAMR-0.18.0`
- Overlay evidence: `evidence/`
- Persistent execution scripts: `/home/data/smarties-local/e01980e8e06a/scripts/overlay-*.sh`
- Consumer environment interface: `/home/data/smarties-local/e01980e8e06a/evidence/resolved-environment.env`
- No tracked production file is created or modified by this overlay plan.

---

### Task 1: Freeze and copy immutable dependency sources

**Files:**
- Create: `deps/ibamr-samrai-subcomm-v1/src/IBSAMRAI2-2025.10.29/`
- Create: `deps/ibamr-samrai-subcomm-v1/src/IBAMR-0.18.0/`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/input-identities.sha256`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/environment.txt`

**Interfaces:**
- Consumes: immutable AutoIBAMR sources and Task 2 verified Smarties source.
- Produces: untouched source copies and input identities consumed by the patch/build tasks.

- [ ] **Step 1: Prove all targets are new and record the input environment**

Run inside the container:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
test ! -e "$overlay"
test -f /root/autoibamr/tmp/unpack/IBSAMRAI2-2025.10.29/configure
test -f /root/autoibamr/tmp/unpack/IBAMR-0.18.0/CMakeLists.txt
mkdir -p "$overlay/src" "$overlay/build/samrai" "$overlay/packages" "$overlay/evidence"
# shellcheck disable=SC1091
source /root/autoibamr/configuration/enable.sh
{
  date --iso-8601=seconds
  gcc --version | head -n 1
  g++ --version | head -n 1
  mpiexec --version | head -n 1
  cmake --version | head -n 1
  printf 'cpu_set=0,2\n'
} > "$overlay/evidence/environment.txt"
```

Expected: the overlay did not exist and only the new overlay directories were created.

- [ ] **Step 2: Hash immutable input trees and the patch before copying**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
{
  find /root/autoibamr/tmp/unpack/IBSAMRAI2-2025.10.29 -type f -print0 | sort -z | xargs -0 sha256sum
  find /root/autoibamr/tmp/unpack/IBAMR-0.18.0 -type f -print0 | sort -z | xargs -0 sha256sum
  sha256sum "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch"
} > "$overlay/evidence/input-identities.sha256"
```

Expected: zero exit and a nonempty manifest containing both source prefixes and the patch.

- [ ] **Step 3: Copy the two source trees without following later build outputs**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
cp -a /root/autoibamr/tmp/unpack/IBSAMRAI2-2025.10.29 "$overlay/src/"
cp -a /root/autoibamr/tmp/unpack/IBAMR-0.18.0 "$overlay/src/"
test -f "$overlay/src/IBSAMRAI2-2025.10.29/configure"
test -f "$overlay/src/IBAMR-0.18.0/CMakeLists.txt"
```

Expected: both copied sources exist under the overlay and no `/root` path changed.

- [ ] **Step 4: Prove the SAMRAI copy initially matches the immutable input**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
diff -qr /root/autoibamr/tmp/unpack/IBSAMRAI2-2025.10.29 "$overlay/src/IBSAMRAI2-2025.10.29" > "$overlay/evidence/samrai-copy-diff.txt"
diff -qr /root/autoibamr/tmp/unpack/IBAMR-0.18.0 "$overlay/src/IBAMR-0.18.0" > "$overlay/evidence/ibamr-copy-diff.txt"
test ! -s "$overlay/evidence/samrai-copy-diff.txt"
test ! -s "$overlay/evidence/ibamr-copy-diff.txt"
```

Expected: both diff files are empty.

---

### Task 2: Apply and prove the SAMRAI communicator patch

**Files:**
- Modify: `deps/ibamr-samrai-subcomm-v1/src/IBSAMRAI2-2025.10.29/` at the exact patch hunks.
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/patch-forward-dry-run.log`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/patch-apply.log`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/patch-reverse-dry-run.log`
- Create: `deps/ibamr-samrai-subcomm-v1/PATCHED_SMARTIES_SAMRAI.sha256`

**Interfaces:**
- Consumes: Task 1 pristine SAMRAI copy and repository patch.
- Produces: one demonstrably patched SAMRAI source and immutable patch marker.

- [ ] **Step 1: RED — prove the pristine copy does not satisfy reverse dry-run**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
set +e
patch --batch --dry-run -R -d "$overlay/src/IBSAMRAI2-2025.10.29" -p1 -i "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$overlay/evidence/patch-pristine-reverse.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$overlay/evidence/patch-pristine-reverse.exit"
test "$status" -ne 0
```

Expected: nonzero exit, demonstrating the copy is not already patched.

- [ ] **Step 2: Prove the forward dry-run succeeds**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
patch --batch --dry-run -d "$overlay/src/IBSAMRAI2-2025.10.29" -p1 -i "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$overlay/evidence/patch-forward-dry-run.log" 2>&1
```

Expected: zero exit and every hunk checks cleanly.

- [ ] **Step 3: Apply the patch exactly once**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
patch --batch -d "$overlay/src/IBSAMRAI2-2025.10.29" -p1 -i "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$overlay/evidence/patch-apply.log" 2>&1
```

Expected: zero exit and no rejected hunk.

- [ ] **Step 4: GREEN — prove reverse dry-run and exact source test now pass**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
patched=$overlay/src/IBSAMRAI2-2025.10.29
patch --batch --dry-run -R -d "$patched" -p1 -i "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$overlay/evidence/patch-reverse-dry-run.log" 2>&1
SAMRAI_SOURCE_ROOT="$patched" bash "$root/source/couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh" > "$overlay/evidence/samrai-source-test.log" 2>&1
patch_sha=$(sha256sum "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" | awk '{print $1}')
printf '%s\n' "$patch_sha" > "$overlay/PATCHED_SMARTIES_SAMRAI.sha256"
test "$(wc -c < "$overlay/PATCHED_SMARTIES_SAMRAI.sha256")" -eq 65
```

Expected: reverse dry-run and repository patch test both exit zero; marker is one 64-hex SHA-256 plus newline.

---

### Task 3: Build and install patched SAMRAI

**Files:**
- Create: `deps/ibamr-samrai-subcomm-v1/build/samrai/`
- Create: `deps/ibamr-samrai-subcomm-v1/packages/IBSAMRAI2-2025.10.29/`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/samrai-configure.log`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/samrai-build.log`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/samrai-install.log`

**Interfaces:**
- Consumes: Task 2 patched source and immutable AutoIBAMR HDF5/Silo packages.
- Produces: patched SAMRAI installation used exclusively by Task 4.

- [ ] **Step 1: Configure with the original installed SAMRAI options and overlay prefix**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
source /root/autoibamr/configuration/enable.sh
export CC=/usr/bin/mpicc CXX=/usr/bin/mpicxx F77=/usr/bin/mpif90
cd "$overlay/build/samrai"
taskset -c 0,2 "$overlay/src/IBSAMRAI2-2025.10.29/configure" --with-F77=/usr/bin/mpif90 --with-hdf5=/root/autoibamr/packages/hdf5-1.12.2 --without-petsc --without-hypre --without-blaslapack --without-cubes --without-eleven --without-kinsol --without-sundials --without-x --enable-dcomplex --enable-implicit-template-instantiation --disable-deprecated 'CFLAGS=-fPIC -O2' 'CXXFLAGS=-fPIC -O2' 'FFLAGS=-fPIC -O2' --with-silo=/root/autoibamr/packages/silo-4.11-bsd --prefix="$overlay/packages/IBSAMRAI2-2025.10.29" > "$overlay/evidence/samrai-configure.log" 2>&1
```

Expected: zero exit and `config.status --config` reports the overlay prefix with `/usr/bin/mpicc`, `/usr/bin/mpicxx`, and `/usr/bin/mpif90`.

- [ ] **Step 2: Build with two jobs on two physical cores**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
taskset -c 0,2 make -C "$overlay/build/samrai" -j2 > "$overlay/evidence/samrai-build.log" 2>&1
```

Expected: zero exit and no failed target.

- [ ] **Step 3: Install into the overlay package directory**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
taskset -c 0,2 make -C "$overlay/build/samrai" install > "$overlay/evidence/samrai-install.log" 2>&1
test -f "$overlay/packages/IBSAMRAI2-2025.10.29/lib/libSAMRAI.a"
test -f "$overlay/packages/IBSAMRAI2-2025.10.29/lib/libSAMRAI2d_hier.a"
```

Expected: both core and 2D hierarchy libraries exist under the overlay.

- [ ] **Step 4: Record installed SAMRAI identities**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
find "$overlay/packages/IBSAMRAI2-2025.10.29" -type f -print0 | sort -z | xargs -0 sha256sum > "$overlay/evidence/samrai-install.sha256"
test -s "$overlay/evidence/samrai-install.sha256"
```

Expected: nonempty installed-file manifest.

---

### Task 4: Build and install IBAMR against patched SAMRAI

**Files:**
- Create: `deps/ibamr-samrai-subcomm-v1/build/ibamr/`
- Create: `deps/ibamr-samrai-subcomm-v1/packages/IBAMR-0.18.0/`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/ibamr-configure.log`
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/ibamr-build-install.log`

**Interfaces:**
- Consumes: Task 3 patched SAMRAI installation and immutable AutoIBAMR dependency packages.
- Produces: overlay `IBAMRConfig.cmake` consumed by the Smarties coupling build.

- [ ] **Step 1: Configure IBAMR with only `SAMRAI_ROOT` and install prefix redirected**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
source /root/autoibamr/configuration/enable.sh
unset SAMRAI_DIR IBAMR_ROOT
taskset -c 0,2 cmake -S "$overlay/src/IBAMR-0.18.0" -B "$overlay/build/ibamr" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/mpicc -DCMAKE_CXX_COMPILER=/usr/bin/mpicxx -DCMAKE_INSTALL_PREFIX="$overlay/packages/IBAMR-0.18.0" -DIBAMR_ENABLE_DOCUMENTATION=OFF -DIBAMR_ENABLE_TESTING=OFF -DIBAMR_FORCE_BUNDLED_Eigen3=ON -DIBAMR_FORCE_BUNDLED_muParser=ON -DHDF5_ROOT=/root/autoibamr/packages/hdf5-1.12.2 -DHYPRE_ROOT=/root/autoibamr/packages/petsc-3.23.3 -DPETSC_ROOT=/root/autoibamr/packages/petsc-3.23.3 -DLIBMESH_ROOT=/root/autoibamr/packages/libmesh-1.7.8 -DLIBMESH_METHOD=OPT -DSAMRAI_ROOT="$overlay/packages/IBSAMRAI2-2025.10.29" -DSILO_ROOT=/root/autoibamr/packages/silo-4.11-bsd > "$overlay/evidence/ibamr-configure.log" 2>&1
```

Expected: zero exit; `CMakeCache.txt` records overlay SAMRAI paths and immutable `/root` paths only for the allowed prerequisite packages.

- [ ] **Step 2: Build and install IBAMR with two jobs**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
taskset -c 0,2 cmake --build "$overlay/build/ibamr" --target install --parallel 2 > "$overlay/evidence/ibamr-build-install.log" 2>&1
```

Expected: zero exit and install target completes.

- [ ] **Step 3: Verify overlay IBAMR package identity and dependency selection**

Run:

```bash
set -euo pipefail
overlay=/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1
config="$overlay/packages/IBAMR-0.18.0/lib/cmake/ibamr/IBAMRConfig.cmake"
test -f "$config"
grep -F "SAMRAI_ROOT:UNINITIALIZED=$overlay/packages/IBSAMRAI2-2025.10.29" "$overlay/build/ibamr/CMakeCache.txt"
if grep -F 'SAMRAI_ROOT:UNINITIALIZED=/root/autoibamr/packages/IBSAMRAI2-2025.10.29' "$overlay/build/ibamr/CMakeCache.txt"; then exit 65; fi
find "$overlay/packages/IBAMR-0.18.0" -type f -print0 | sort -z | xargs -0 sha256sum > "$overlay/evidence/ibamr-install.sha256"
```

Expected: overlay config exists, cache points only to overlay SAMRAI, and installed manifest is nonempty.

---

### Task 5: Admit the overlay to the coupling build

**Files:**
- Create: `deps/ibamr-samrai-subcomm-v1/evidence/overlay-verification.txt`
- Replace: `/home/data/smarties-local/e01980e8e06a/evidence/resolved-environment.env`

**Interfaces:**
- Consumes: Tasks 2-4 patch/build/install identities.
- Produces: the exact environment file expected by the main local Docker validation plan.

- [ ] **Step 1: Re-run patch proof and repository source test after all builds**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
patched=$overlay/src/IBSAMRAI2-2025.10.29
patch --batch --dry-run -R -d "$patched" -p1 -i "$root/source/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch" > "$overlay/evidence/final-patch-reverse.log" 2>&1
SAMRAI_SOURCE_ROOT="$patched" bash "$root/source/couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh" > "$overlay/evidence/final-samrai-source-test.log" 2>&1
```

Expected: both checks exit zero.

- [ ] **Step 2: Write the consumer environment atomically**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
overlay=$root/deps/ibamr-samrai-subcomm-v1
env_file=$root/evidence/resolved-environment.env
tmp=$env_file.tmp.$$
printf 'IBAMR_DIR=%q\nSAMRAI_SOURCE_ROOT=%q\nCC=%q\nCXX=%q\nCPU_SET=%q\nOVERLAY_ROOT=%q\n' "$overlay/packages/IBAMR-0.18.0/lib/cmake/ibamr" "$overlay/src/IBSAMRAI2-2025.10.29" /usr/bin/gcc /usr/bin/g++ 0,2 "$overlay" > "$tmp"
mv "$tmp" "$env_file"
```

Expected: `IBAMR_DIR` and `SAMRAI_SOURCE_ROOT` point only inside the overlay; `CC`, `CXX`, and `CPU_SET` remain `/usr/bin/gcc`, `/usr/bin/g++`, and `0,2`.

- [ ] **Step 3: Verify no original install path can be selected accidentally**

Run:

```bash
set -euo pipefail
root=/home/data/smarties-local/e01980e8e06a
source "$root/evidence/resolved-environment.env"
case "$IBAMR_DIR" in "$OVERLAY_ROOT"/*) ;; *) exit 65 ;; esac
case "$SAMRAI_SOURCE_ROOT" in "$OVERLAY_ROOT"/*) ;; *) exit 65 ;; esac
test -f "$IBAMR_DIR/IBAMRConfig.cmake"
test -f "$OVERLAY_ROOT/PATCHED_SMARTIES_SAMRAI.sha256"
{
  cat "$root/evidence/resolved-environment.env"
  sha256sum "$OVERLAY_ROOT/PATCHED_SMARTIES_SAMRAI.sha256" "$IBAMR_DIR/IBAMRConfig.cmake"
  du -sh "$OVERLAY_ROOT"
} > "$OVERLAY_ROOT/evidence/overlay-verification.txt"
```

Expected: every consumer path is inside the overlay and verification evidence is nonempty.

- [ ] **Step 4: Resume the main local Docker validation plan**

Resume at Task 3, configure step in
`docs/superpowers/plans/2026-08-11-local-docker-coupling-validation.md`.
The earlier root-install patch-gate failure remains preserved and is not
reclassified as a passing attempt.
