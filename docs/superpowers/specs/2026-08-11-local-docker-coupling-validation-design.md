# Local Docker validation for the eel2d coupling

## Goal

Use the existing Docker Desktop container named `ibamr` to rerun the current
eel2d coupling validation without node3 CPU contention. Smarties does not need
to be preinstalled in the container: the clean Smarties source package will be
compiled together with the coupling targets against the IBAMR installation
already present under `/root`.

This validation is intended to distinguish a functional regression from the
resource-contention timeouts observed on node3. It does not replace a final
node3 admission run when exact node3 toolchain and runtime equivalence cannot
be demonstrated.

## Existing environment boundary

- Docker is managed by Docker Desktop on the Windows host.
- The persistent container is named `ibamr`.
- Host directory `D:\dataset_ib` is mapped to `/home/data` in the container.
- IBAMR is installed somewhere below `/root`; its exact prefix, version, and
  companion PETSc, MPI, compiler, and Silo installations must be discovered
  read-only before configuring the build.
- Existing files below `/root` are treated as immutable dependencies. This
  task must not reinstall, overwrite, or patch the container's IBAMR stack.

## Fixed coupling architecture

The local environment changes only where the tests execute. It does not change
the coupling design:

- `CouplingDriver` remains the sole owner of `MPI_Init_thread()` and
  `MPI_Finalize()`.
- Smarties borrows the communicator supplied by the driver and never privately
  finalizes MPI or frees a caller-owned communicator.
- Only environment ranks initialize PETSc, SAMRAI, IBTK, and IBAMR, with
  `PETSC_COMM_WORLD` set to the environment communicator first.
- IBAMR owns CFD time advancement; state, action, reward, terminal status, and
  reset commands cross the adapter only at explicit safe points.
- The current Smarties CPU learner remains in use. PyTorch, CUDA, pybind11, and
  Python bindings are outside this validation.
- Fatal distributed failures converge through `MPI_Abort`; normal destruction
  remains inside-out with driver-owned finalization last.

## Selected approach

Use the existing container as a read-only dependency environment while keeping
all task-owned files below `/home/data`. Copy the clean `e01980e8e06a77a54071dc97ea029b5d80a49321`
source archive into `D:\dataset_ib\smarties-local`, verify its SHA-256 on both
sides of the mapping, and extract it into a revision-specific source directory.
Create separate revision-specific build, run, and evidence directories beside
the source directory.

Configure an out-of-source release build with `COMPILE_PY_SO=OFF`. The build
must produce its own `libsmarties.so` under the build tree and bind the coupling
executables to that exact file. No generated library may be written into the
source directory or `/root` installation.

This approach is preferred over modifying the persistent container or creating
a derived image because it is sufficient for the immediate diagnostic, leaves
the installed IBAMR stack untouched, and makes every generated artifact visible
through the existing host mapping. A derived image can be considered later if
the local environment becomes a long-term reproducible test target.

## Resource policy

Run the validation serially. Allocate at most two physical CPU cores to the
container-side test process and do not run CTest cases concurrently. The
frequency probe and current eel environment use one MPI rank; additional ranks
or OpenMP threads are not introduced merely to shorten this diagnostic because
the eel multi-rank path has not yet passed admission.

CPU affinity may be used only after the host-to-container CPU topology is
recorded. Affinity is an execution constraint, not a change to simulation or
coupling semantics.

## Inspection and compatibility gate

Before building, record:

- container image identity and container status;
- host and Docker-visible CPU counts;
- exact IBAMR prefix and version;
- compiler and CMake versions;
- MPI implementation and version;
- PETSc and SAMRAI/IBTK configuration exposed by the IBAMR installation;
- presence and version of Silo headers and libraries;
- available disk space below `/home/data`.

The coupling build proceeds only after either the immutable installed stack or
the approved isolated overlay passes its compatibility gate. Version
differences from node3 must be recorded as limitations. A local build failure
caused by incompatible dependencies is evidence about local portability, not
evidence of a coupling regression.

## Approved isolated dependency overlay

The environment inventory demonstrated that the installed IBAMR stack is
IBAMR 0.18.0 with PETSc 3.23.3, SAMRAI 2025.10.29, and Silo 4.11, built with
GCC 10.2.1 and OpenMPI 4.1.0. It also demonstrated that the immutable SAMRAI
source below `/root/autoibamr` still uses `MPI_COMM_WORLD` at every location
covered by `ibsamrai2-subcommunicator.patch`. A reverse patch dry-run therefore
exits nonzero and the installed stack cannot admit the required multi-rank
environment tests.

Build a local dependency overlay below
`/home/data/smarties-local/e01980e8e06a/deps/ibamr-samrai-subcomm-v1`.
The overlay has four isolated areas:

- `src/` contains copies of the immutable SAMRAI and IBAMR source trees;
- `build/` contains their out-of-source build trees;
- `packages/` contains the overlay SAMRAI and IBAMR installations; and
- `evidence/` contains source hashes, configuration commands, logs, installed
  library identities, and a patch marker.

Only the SAMRAI copy receives the existing repository patch. PETSc, HDF5,
libMesh, Silo, and other prerequisites remain read-only inputs from
`/root/autoibamr/packages`. The existing `/root` SAMRAI and IBAMR sources,
builds, and installations are never patched, overwritten, or used as cleanup
targets.

The overlay uses the container's existing `/root/autoibamr/configuration/enable.sh`
environment, GCC 10.2.1, and OpenMPI 4.1.0. SAMRAI and IBAMR are built with at
most two parallel jobs while bound to two different container-visible physical
cores. Python bindings, PyTorch, CUDA, and additional learning backends remain
disabled.

The patch is admitted only when all of these checks pass:

- the copied pristine SAMRAI tree matches the source input identity recorded
  before modification;
- a forward patch dry-run succeeds, the actual patch applies once, and a
  reverse dry-run succeeds afterward;
- the patch SHA-256 is written to the overlay marker;
- the overlay SAMRAI installation and IBAMR `IBAMRConfig.cmake` exist;
- the coupling configuration resolves `IBAMR_DIR` to the overlay, not the
  original `/root` IBAMR installation; and
- the registered `samrai_subcommunicator_patch` test runs against the copied,
  patched SAMRAI source.

If the copied source cannot be configured from the installed dependency set,
the overlay build stops with its logs intact. It must not fall back to the
unpatched IBAMR installation, omit multi-rank tests, relax test timeouts, or
modify `/root` to force progress.

The overlay changes only the dependency implementation used by the local
validation. `CouplingDriver` remains the sole MPI owner; Smarties continues to
borrow its communicator; learner ranks never initialize the CFD stack; only
environment ranks initialize PETSc/SAMRAI/IBTK/IBAMR; normal shutdown remains
inside-out; fatal distributed failures still converge through `MPI_Abort`.

## Verification flow

Verification increases in scope:

1. Verify clean source metadata and the archive manifest after extraction.
2. Copy the SAMRAI and IBAMR sources, apply and prove the communicator patch,
   then build the isolated dependency overlay.
3. Configure and build all required Smarties and eel coupling targets against
   the overlay IBAMR installation.
4. Verify executable, `libsmarties.so`, RPATH, overlay dependency paths, and
   runtime `ldd` identity.
5. Run focused topology, layout invariant, failure-wrapper, and protocol tests.
6. Run the complete 19-test CTest suite serially with existing test timeouts.
7. If the complete suite passes, run the official medium-grid, ratio-1 physical
   probe and preserve the input, command, hashes, output, and exit status.
8. Inspect Silo cycles 0, 40, and 80 and require 2932 finite unique Lagrangian
   points with maximum coordinate multiplicity one.
9. Run the existing invalid coarse guard and require the exact layout mismatch
   diagnostic before any control transition.
10. Check for residual MPI and coupling processes after each terminal run.

Do not increase a timeout or rerun a failed case until the original failure,
machine load, process topology, and logs have been preserved. Any subsequent
rerun receives a new evidence directory.

## Evidence and claim boundary

All raw outputs belong under a revision-specific `/home/data/smarties-local`
evidence directory and may be mirrored into the repository's ignored
`.artifacts` investigation area. Record exact commands, environment versions,
source and binary hashes, process counts, CPU allocation, expected results,
actual results, and limitations.

Local success may establish that the `e01980e` implementation functions in the
local Docker IBAMR environment and that the node3 timeout is not reproduced
there. It cannot by itself prove that node3 contention was the sole cause, nor
can it replace a clean node3 run for claims tied to node3's GCC 8.5.0,
IBAMR 0.18.0, PETSc 3.23.3, or OpenMPI 5.0.9 environment.

No result is promoted into `experience/verified` unless the project closure
gate is independently satisfied, including repeated target-path runs, normal
and failure shutdown, exact revisions, complete evidence, and an explicit
claim boundary.

## Failure handling and cleanup

- A configuration or compilation failure stops before running tests and leaves
  its logs intact.
- A test timeout or nonzero result stops the physical-evidence phase; it is not
  hidden by relaxed timeouts.
- An unrecoverable distributed failure must use the existing `MPI_Abort` path;
  no component attempts private MPI finalization.
- Task-owned build and evidence directories may be replaced only after their
  exact absolute paths are checked. Existing `/root` installations and
  unrelated `/home/data` content are never cleanup targets.

## Completion criteria

This local validation task is complete when the environment inventory, clean
build provenance, focused tests, full serial CTest result, physical medium-grid
result or its gated failure, Silo inspection where applicable, shutdown checks,
and node3-equivalence limitations are all recorded. Completion does not imply
merge admission unless the separate branch-level admission criteria also pass.
