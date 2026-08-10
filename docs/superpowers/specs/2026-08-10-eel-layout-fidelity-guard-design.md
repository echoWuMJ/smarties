# Eel layout fidelity guard and official-grid verification

## Goal

Prevent an eel2d run from advancing when the official kinematics layout and
the loaded Lagrangian vertex count disagree, then verify one real node3 run at
the official grid density. This task does not redesign the official body
formula or the Smarties–IBAMR coupling architecture.

## Demonstrated problem

The official `eel2d.vertex` contains 2932 points. `IBEELKinematics` sizes its
shape arrays from that Lagrangian index range but reconstructs its section
layout from the finest Eulerian mesh spacing. The added coarse profile yields
76 layout points, so the first shape update writes 76 entries and leaves 2856
entries at a shared default coordinate. The existing fine profile would yield
11232 layout points and can write beyond a 2932-entry shape array.

This mismatch also occurs in a single-process `frequency_response_probe`, so
MPI and Smarties transport are outside the root-cause scope.

## Scope and fixed architecture

- Preserve the official eel body envelope, deformation formulas, phase law,
  point ordering, and shape-update algorithm.
- Preserve driver-owned MPI initialization/finalization, borrowed Smarties
  communicators, environment-only PETSc/IBAMR initialization, and CPU learning.
- Do not add a new vertex generator, remeshing, PyTorch, CUDA, or reset support.
- Temporarily support physical eel2d runs only at the official grid density:
  `N=64`, `MAX_LEVELS=3`, `REF_RATIO=4`.
- Keep invalid calibration and failed-run evidence under `.artifacts`; do not
  promote it into `experience/verified`.

## Design

### Layout invariant

Add a small pure validation function that accepts:

- the number of points represented by `d_ImmersedBodyData`;
- the Lagrangian point count from `getLagIdxRange()`; and
- the finest-grid spacing for diagnostics.

It returns normally only when the counts are equal. Otherwise it throws a
descriptive exception containing both counts and the grid spacing.

`IBEELKinematics::setImmersedBodyLayout()` will sum the existing section counts
after building `d_ImmersedBodyData` and invoke this validator before any shape
or velocity update. The existing formulas are not changed. On a coupled run,
the adapter's existing fatal-error path reports the exception and coordinates
`MPI_Abort`; no component privately finalizes MPI.

### Supported fidelity surface

The node3 launcher will reject `coarse`, `fine`, and `curriculum` for physical
eel2d execution before launching MPI. `medium` remains the only accepted
physical fidelity until fidelity-specific Lagrangian discretizations are
designed and verified, and the launcher default changes from `coarse` to
`medium`. The C++ invariant remains mandatory so direct executable use cannot
bypass safety.

Existing real-environment CMake fixtures will render `medium.conf` instead of
the invalid coarse profile. Script-only tests will verify that unsupported
fidelities are rejected and medium is accepted.

The invalid `speed_tracking_node3_coarse.conf` calibration will be removed from
the supported configuration surface, and its README claims will be retracted.
No medium target-speed calibration is created by this task.

## Test-driven implementation

1. Add a failing pure unit test that requires:
   - `2932 == 2932` to pass;
   - `76 != 2932` to throw with both counts in the message; and
   - `11232 != 2932` to throw.
2. Run the focused target and record the expected compile/link failure because
   the validator does not yet exist.
3. Implement the validator and integrate it into
   `setImmersedBodyLayout()` without changing the layout formula.
4. Add failing launcher tests for rejecting coarse, fine, and curriculum, then
   minimally restrict the supported fidelity set to medium.
5. Switch real-environment fixtures to medium and run the focused unit/static
   tests before packaging.

## Node3 official-grid verification

Package one clean immutable revision, verify its source manifest on node3, and
build with GCC/G++ 8.5.0 and the existing IBAMR 0.18.0 environment.

Run one fresh, single-process `frequency_response_probe` at ratio 1.0 with the
official medium input and one control decision. Store the command, exit code,
stdout, input hash, executable hash, and Silo dumps under an isolated evidence
directory.

Read the actual Silo point meshes at cycles 0, 40, and 80 through the Silo C
API. Admission for this task requires all of the following:

- every inspected cycle contains 2932 elements;
- every inspected cycle contains 2932 unique finite coordinates;
- maximum exact coordinate multiplicity is one;
- the run exits zero;
- phase advance matches actual elapsed time and ratio;
- no residual probe/MPI process remains immediately after exit.

Also run an invalid coarse initialization once and require the new mismatch
diagnostic before any controlled transition. This is a negative guard test,
not a physical simulation result.

## Completion boundary

Success establishes only that the official-grid case preserves all loaded
Lagrangian points and that invalid point-count/grid combinations fail fast. It
does not restore multiple fidelities, validate a learned policy, establish grid
convergence, or rehabilitate any earlier coarse calibration or response data.
