# Fixed coupling architecture contract

This contract applies to every IBAMR-Smarties case. It defines ownership and lifecycle; it is not evidence that an implementation has passed verification.

## Process and ownership

Run one MPI job with a long-lived coupling driver. The driver calls `MPI_Init_thread()` exactly once, splits `MPI_COMM_WORLD`, and calls `MPI_Finalize()` exactly once after every owned object is destroyed.

Split ranks into:

- learner ranks, which run Smarties learning and do not initialize the CFD stack;
- one environment communicator per IBAMR simulation, containing only that simulation's ranks.

Use dedicated MPI ranks for environments (`workerProcessesPerEnv >= 1`). Learner and environment ranks are disjoint. Do not fork after MPI initialization. Every library below the driver borrows MPI.

## Communicator ownership

The driver owns the communicator passed across the coupling boundary. Smarties borrowed mode may `MPI_Comm_dup` it and create derived communicators. Smarties frees only those duplicates and derivatives; it must not free the caller's communicator, `MPI_COMM_WORLD`, or `MPI_COMM_SELF`, and must not finalize MPI.

Before PETSc or `IBTKInit` starts on environment ranks, assign that environment communicator to `PETSC_COMM_WORLD`. PETSc, SAMRAI, IBTK, and IBAMR exist only on environment ranks, use the same environment communicator, and are destroyed before those ranks leave the worker callback. Restore SAMRAI's active communicator after `IBTKInit` if initialization changes it.

Any hard-coded `MPI_COMM_WORLD` inside an environment-side dependency is incompatible with multi-environment isolation and must be handled by a version-specific source overlay or an upstream-compatible fix.

## Control boundary

IBAMR owns the CFD setup and time loop. At explicit safe synchronization points, an adapter:

1. extracts observation state from the current IBAMR solution;
2. blocks in `recvAction()` while IBAMR time remains unchanged, then receives and applies one bounded action;
3. advances IBAMR to the next control point;
4. computes reward and terminal status;
5. performs a controlled reset only at a defined episode boundary.

State, action, reward, cadence, terminal criteria, and reset mechanics are case-specific. MPI ownership and process topology are not. Do not apply an action midway through an IBAMR step or advance a partial control interval.

## Reset and shutdown

A Smarties segment boundary is a protocol boundary, not an automatic CFD reset. Each case must declare whether the next segment continues the same hierarchy, flow, geometry, time, and controller state; partially resets selected state; or reconstructs the complete physical environment.

Normal shutdown order is:

1. stop admitting new episodes;
2. reach a safe control boundary and publish the final transition;
3. destroy case objects, IBAMR, SAMRAI, IBTK, and PETSc resources;
4. return from the environment callback;
5. let Smarties drain messages and free only its owned communicators;
6. return all ranks to the coupling driver;
7. let the driver call `MPI_Finalize()`.

A numerical episode failure should become a terminal transition and controlled reset only when every participating rank can reach the same usable boundary. An unrecoverable distributed failure must be coordinated and end with `MPI_Abort` on the relevant communicator. No component may attempt a private `MPI_Finalize()` recovery.

## CPU baseline

Use Smarties' existing CPU neural-network path for the initial coupling. Do not add PyTorch, CUDA, pybind11, or a second Python runtime as part of coupling work unless the user explicitly opens a separate migration phase.

## Review invariants

Reject a design or patch if any answer is unclear:

- Which component owns MPI initialization and finalization?
- Which ranks initialize IBAMR/PETSc?
- Which exact communicator does each subsystem use?
- Can any code fork after MPI initialization?
- Can any borrowed component finalize MPI or free a caller-owned communicator?
- At what safe point are actions applied and episodes reset?
- Is the declared reset logical continuation, partial reset, or full physical reset?
- Does normal and fatal shutdown converge across all ranks?
