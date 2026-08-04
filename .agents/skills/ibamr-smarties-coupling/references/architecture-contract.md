# Fixed coupling architecture contract

This document freezes the long-term process and ownership model for IBAMR-Smarties coupling. It is a project design contract, not evidence that an implementation has already passed.

## Process topology

Run one MPI job with a long-lived coupling driver. Split `MPI_COMM_WORLD` into:

- learner ranks, which run Smarties learning and do not initialize the CFD stack;
- one environment communicator per IBAMR simulation, containing only that simulation's ranks.

Use dedicated MPI ranks for environments (`workerProcessesPerEnv >= 1`). Do not use process forking after MPI initialization.

The driver calls `MPI_Init_thread()` exactly once and `MPI_Finalize()` exactly once. Every library below it borrows MPI.

## Communicator ownership

The driver owns the communicator passed across the coupling boundary. Smarties borrowed mode may `MPI_Comm_dup` it and create derived communicators. Smarties frees only those duplicates and derivatives; it must not free the caller's communicator, `MPI_COMM_WORLD`, or `MPI_COMM_SELF`, and must not finalize MPI.

Before PETSc or `IBTKInit` starts on environment ranks, assign that environment communicator to `PETSC_COMM_WORLD`. PETSc, SAMRAI, IBTK, and IBAMR exist only on environment ranks and are destroyed before those ranks leave the worker callback.

## Control boundary

IBAMR owns the CFD setup and time loop. At explicit safe synchronization points, an adapter:

1. extracts observation state from the current IBAMR solution;
2. receives an action from Smarties and applies bounded control parameters;
3. advances IBAMR to the next control point;
4. computes reward and terminal status;
5. performs a controlled reset only at a defined episode boundary.

State, action, reward, cadence, terminal criteria, and reset mechanics are case-specific. MPI ownership and process topology are not.

## Shutdown protocol

Normal shutdown order is:

1. stop admitting new episodes;
2. reach a safe control boundary and publish the final transition;
3. destroy case objects, IBAMR, SAMRAI, IBTK, and PETSc resources;
4. return from the environment callback;
5. let Smarties drain messages and free only its owned communicators;
6. return all ranks to the coupling driver;
7. let the driver call `MPI_Finalize()`.

A numerical episode failure should become a terminal transition and controlled reset when the solver remains usable. An unrecoverable distributed failure must be coordinated and end with `MPI_Abort` on the relevant communicator. No component may attempt a private `MPI_Finalize()` recovery.

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
- Does normal and fatal shutdown converge across all ranks?
