# node3 Smarties uv Installation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the local smarties source tree on node3, manage its Python tooling with uv and CPython 3.12, and build a C++ smarties library compatible with the existing IBAMR toolchain.

**Architecture:** The local working tree is archived without Git metadata or generated build products and uploaded to a staging directory on node3. uv and its managed CPython live under `/data2/mjwu/local`, while the smarties source, `.venv`, build directory, and produced library live under `/data2/mjwu/local/smarties`. The first build disables the optional pybind11 module because the local pybind11 submodule is empty; IBAMR couples directly to `libsmarties.so`, while Python 3.12 runs the smarties launcher and experiment tooling.

**Tech Stack:** smarties commit `34c53d1ef03a324b20b418eaac6343ba44b6c966`, uv, CPython 3.12, psutil, GCC 8.5.0, CMake 3.30.6, OpenMPI 5.0.9, OpenMP, PETSc OpenBLAS 0.3.29.

## Global Constraints

- Use only user-writable paths below `/data2/mjwu`; do not require root privileges.
- Use domestic mirrors or the already reachable GitHub proxy for network downloads.
- Python must report version 3.12 from `/data2/mjwu/local/smarties/.venv/bin/python`.
- Build smarties with `COMPILE_PY_SO=OFF`; do not silently claim that the optional Python extension was built.
- Link smarties to `/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib/libopenblas.so`.
- Preserve the existing IBAMR GCC 8.5.0 and OpenMPI 5.0.9 toolchain.
- Do not commit or discard existing local working-tree changes.

---

### Task 1: Package and stage the local source

**Files:**
- Create: `C:/Users/wumj/Project/smarties/.artifacts/smarties-local-34c53d1.tar.gz`
- Create remotely: `/data2/mjwu/Downloads/smarties-offline/smarties-local-34c53d1.tar.gz`

**Interfaces:**
- Consumes: the current local smarties working tree, including `experience/`.
- Produces: a checksum-verified source archive whose root extracts directly into `SMARTIES_ROOT`.

- [ ] **Step 1: Create a clean source archive**

  Run from `C:/Users/wumj/Project/smarties`:

  ```powershell
  New-Item -ItemType Directory -Force .artifacts
  tar -czf .artifacts/smarties-local-34c53d1.tar.gz --exclude=.git --exclude=.codebase-memory --exclude=.artifacts --exclude=build --exclude=build-node3 --exclude=lib .
  ```

- [ ] **Step 2: Verify archive contents and checksum**

  ```powershell
  tar -tzf .artifacts/smarties-local-34c53d1.tar.gz | Select-Object -First 20
  Get-FileHash .artifacts/smarties-local-34c53d1.tar.gz -Algorithm SHA256
  ```

  Expected: `CMakeLists.txt`, `source/`, `include/`, `apps/`, and `experience/` are present; `.git/` is absent.

- [ ] **Step 3: Create staging directory and upload archive**

  Create `/data2/mjwu/Downloads/smarties-offline`, upload the archive with the SSH file-transfer tool, then run:

  ```bash
  sha256sum /data2/mjwu/Downloads/smarties-offline/smarties-local-34c53d1.tar.gz
  ```

  Expected: remote SHA256 equals the local value.

- [ ] **Step 4: Extract the verified archive into `SMARTIES_ROOT`**

  ```bash
  mkdir -p /data2/mjwu/local/smarties
  tar -xzf /data2/mjwu/Downloads/smarties-offline/smarties-local-34c53d1.tar.gz -C /data2/mjwu/local/smarties
  test -f /data2/mjwu/local/smarties/CMakeLists.txt
  ```

  Expected: the source root exists before uv creates the project-local `.venv`.

### Task 2: Install uv and create the Python 3.12 environment

**Files:**
- Create remotely: `/data2/mjwu/local/uv/bin/uv`
- Create remotely: `/data2/mjwu/local/smarties/.venv/`

**Interfaces:**
- Consumes: reachable `ghproxy.net`, npmmirror Python standalone mirror, and the Tsinghua PyPI mirror.
- Produces: an isolated uv-managed CPython 3.12 environment with `psutil`.

- [ ] **Step 1: Install a self-contained uv binary**

  Download the official x86_64 musl archive through the reachable GitHub proxy, extract it under `/data2/mjwu/local/uv`, and verify:

  ```bash
  /data2/mjwu/local/uv/bin/uv --version
  ```

- [ ] **Step 2: Install uv-managed CPython 3.12**

  ```bash
  export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python
  export UV_PYTHON_INSTALL_MIRROR=https://registry.npmmirror.com/-/binary/python-build-standalone
  /data2/mjwu/local/uv/bin/uv python install 3.12
  ```

  Expected: `uv python find 3.12` resolves below `/data2/mjwu/local/uv/python`.

- [ ] **Step 3: Create the project environment and install launcher dependencies**

  ```bash
  cd /data2/mjwu/local/smarties
  export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python
  /data2/mjwu/local/uv/bin/uv venv --python 3.12 .venv
  UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple /data2/mjwu/local/uv/bin/uv pip install --python .venv/bin/python psutil
  .venv/bin/python -c "import sys, psutil; print(sys.version); print(psutil.cpu_count(logical=False))"
  ```

  Expected: Python reports 3.12 and `psutil` imports successfully.

### Task 3: Extract and build smarties against the IBAMR toolchain

**Files:**
- Create remotely: `/data2/mjwu/local/smarties/`
- Create remotely: `/data2/mjwu/local/smarties/build-node3/`
- Create remotely: `/data2/mjwu/local/smarties/lib/libsmarties.so`

**Interfaces:**
- Consumes: staged archive, GCC/OpenMPI compiler wrappers, PETSc CBLAS headers, and PETSc OpenBLAS.
- Produces: the C++ smarties shared library used by IBAMR and example applications.

- [ ] **Step 1: Verify the extracted source root**

  ```bash
  test -f /data2/mjwu/local/smarties/CMakeLists.txt
  test -f /data2/mjwu/local/smarties/source/smarties/Engine.cpp
  test -f /data2/mjwu/local/smarties/include/smarties.h
  ```

- [ ] **Step 2: Configure the C++ build**

  ```bash
  export PATH=/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:/data2/mjwu/autoibamr/packages/cmake-3.30.6/bin:$PATH
  cmake -S /data2/mjwu/local/smarties -B /data2/mjwu/local/smarties/build-node3 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCOMPILE_PY_SO=OFF \
    -DCMAKE_C_COMPILER=/data2/mjwu/local/openmpi/bin/mpicc \
    -DCMAKE_CXX_COMPILER=/data2/mjwu/local/openmpi/bin/mpicxx \
    -DCMAKE_CXX_FLAGS=-I/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/include \
    -DBLAS_LIBRARIES=/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib/libopenblas.so \
    -DCMAKE_BUILD_RPATH=/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib
  ```

  Expected: CMake identifies GCC 8.5.0, OpenMPI, OpenMP, and the requested OpenBLAS.

- [ ] **Step 3: Build the library and C++ cart-pole example**

  ```bash
  cmake --build /data2/mjwu/local/smarties/build-node3 --parallel 8
  SMARTIES_ROOT=/data2/mjwu/local/smarties PATH=/data2/mjwu/local/openmpi/bin:$PATH make -C /data2/mjwu/local/smarties/apps/cart_pole_cpp clean exec
  ```

  Expected: both `lib/libsmarties.so` and `apps/cart_pole_cpp/exec` exist.

### Task 4: Verify the complete installation and document it

**Files:**
- Create locally and remotely: `experience/node3_smarties_uv_install.md`

**Interfaces:**
- Consumes: the uv environment, smarties library, and cart-pole executable.
- Produces: fresh evidence that the launcher, dynamic links, and MPI-facing C++ example are usable, plus reproducible operator commands.

- [ ] **Step 1: Verify uv, Python, launcher, and library links**

  ```bash
  /data2/mjwu/local/uv/bin/uv --version
  /data2/mjwu/local/smarties/.venv/bin/python --version
  /data2/mjwu/local/smarties/.venv/bin/python /data2/mjwu/local/smarties/bin/smarties.py --help
  ldd /data2/mjwu/local/smarties/lib/libsmarties.so
  LD_LIBRARY_PATH=/data2/mjwu/local/smarties/lib:/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib:${LD_LIBRARY_PATH:-} ldd /data2/mjwu/local/smarties/apps/cart_pole_cpp/exec
  ```

  Expected: Python is 3.12; help exits zero; both binaries resolve OpenMPI and the PETSc OpenBLAS without `not found` entries.

- [ ] **Step 2: Exercise MPI initialization without starting a long training run**

  ```bash
  SMARTIES_ROOT=/data2/mjwu/local/smarties \
  LD_LIBRARY_PATH=/data2/mjwu/local/smarties/lib:/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib:${LD_LIBRARY_PATH:-} \
  /data2/mjwu/local/openmpi/bin/mpirun --bind-to none -n 2 /data2/mjwu/local/smarties/apps/cart_pole_cpp/exec --help
  ```

  Expected: the smarties CLI help is printed and the command exits zero.

- [ ] **Step 3: Record exact paths, versions, checksums, build flags, and validation output**

  Write `experience/node3_smarties_uv_install.md` with the actual values observed during Tasks 1-4. Do not replace failed checks with expected results; record any unresolved limitation explicitly.

## Self-review

- Spec coverage: local-source upload, uv-managed environment, Python 3.12, domestic mirrors, smarties build, IBAMR-compatible dependencies, and runtime verification each have a task.
- Placeholder scan: no deferred implementation markers are present.
- Path consistency: staging, uv, Python, source, build, library, and documentation paths are identical across tasks.
