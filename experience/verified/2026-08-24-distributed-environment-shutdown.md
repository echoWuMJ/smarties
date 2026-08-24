# Verified distributed-environment shutdown

- Status: verified
- Verified on: 2026-08-24 (Asia/Shanghai)
- Scope: Smarties borrowed-MPI coupling with one multi-rank environment, including the IBAMR 0.18.0 eel2d path on node03
- Parent revision reproducing the defect: `95834f4cad448f136972ac65bedc38746726633c`
- Fix revision: `a4d0d91ad653d8d8776c43505c62b95285311b4d`
- Evidence candidate: `.artifacts/ibamr-smarties-investigations/distributed-environment-shutdown/candidate.md`
- Reviewer: fresh command rerun and artifact inspection by the primary Codex agent

## Environment

- Host: `node03`
- OS/kernel: CentOS Linux 7, Linux `3.10.0-1160.108.1.el7.x86_64`
- Compiler: GCC/G++ 8.5.0
- MPI: Open MPI 5.0.9
- IBAMR: 0.18.0
- PETSc: 3.23.3
- Smarties neural-network backend: native CPU
- SAMRAI overlay patch SHA-256: `bbfe1e44bd2908545b4923a5d5aa2a4aaa3528f7215d6a59cc792c08793a04e8`
- Fixed executable SHA-256: `cfabaf97967e18d2f1e76151094f91ed073b8caba97510bafe21ffaa141521b2`
- Fixed `libsmarties.so` SHA-256: `d7f58a8d1c1200b68bbdaa612c627b2e46331d6ce7f7164d5e452fe898dd38d3`

## Problem and original symptom

With one learner rank and a multi-rank IBAMR environment, the learner could
finish its requested updates and write the final network snapshot, while the
MPI job remained alive after the final state exchange. In the captured long
run, Smarties reached learner update 32, but `MasterMPI::~MasterMPI()` could not
join its communication handler.

The handler was blocked in `waitForStateActionCallers()`/`PMPI_Wait`. The
environment root was waiting for the learner response, while its peer IBAMR
ranks were waiting in an environment-communicator broadcast. A minimal
three-rank test, consisting of one learner and one two-rank distributed
environment, reproduced the old behavior as a 20.03-second timeout.

Original run artifact:
`/data2/mjwu/local/coupling-src/smarties-ibamr-20260823T154940Z-95834f4cad44/couplings/ibamr/runs/eel2d-20260824T082928Z-95834f4cad44-21851`.

## Demonstrated root cause

`MasterMPI::spawnCallsHandlers()` registered one state/action receive for every
raw worker rank. That assumption is valid when `workerProcessesPerEnv=1`, but
not for a distributed environment. After
`Communicator::envHasDistributedAgents()` is declared, only the root rank of
each environment group exchanges state with the Smarties master. The other
environment ranks participate through their environment communicator.

Consequently, termination waited for state messages from non-root ranks that
were not protocol callers. The deterministic old-code timeout, the matching
live stacks, and the same regression's immediate completion after limiting
master-side callers to environment roots distinguish this defect from slow
IBAMR time stepping or an MPI transport loss.

## Resolution

Every multi-rank environment must call
`comm->envHasDistributedAgents()` on all environment ranks before its first
Smarties state/action exchange. The eel2d smoke and speed-tracking adapters now
make this declaration explicitly.

The Smarties master now derives state/action callers from
`workerProcessesPerEnv` and registers only ranks `0, group_width, 2 *
group_width, ...`. During termination, the environment root receives the
Smarties end signal and the existing distributed-environment protocol
broadcasts it to its peer ranks. The serial case remains unchanged because a
group width of one selects every worker rank.

## Verification matrix

| Check | Command/input | Expected | Actual | Artifact | Result |
|---|---|---|---|---|---|
| Original failure | Parent revision; `ctest -R '^distributed_environment_shutdown$' --output-on-failure -V` | Old code cannot terminate the two-rank distributed environment | Timed out after 20.03 s | Candidate plus parent revision | PASS |
| Fixed regression | Fix revision; same CTest | Callback, driver return, and MPI-finalized markers; exit 0 | Passed in 0.36 s in the final focused run | node03 build `Testing/Temporary/LastTest.log` | PASS |
| Exact distributed topology | `mpiexec -n 17`, one learner plus a synthetic 16-rank environment | All 16 ranks receive termination and driver destroys cleanly | Callback returned for 16 ranks; MPI active before driver destruction and finalized afterward; exit 0 | node03 build and candidate | PASS |
| Real IBAMR topology | `run_node3.sh smoke --envs 1 --ranks-per-env 16 --learner-ranks 1 --learner-threads 1 --fidelity medium --smoke-steps 1` | One real CFD step followed by clean distributed shutdown | `EEL_SMOKE_TERMINAL steps=1`; 16 end signals; exit 0; no residual scoped process | `runs/eel2d-20260824T130938Z-a4d0d91ad653-84687/` | PASS |
| Neighboring CPU protocol | `ctest -R '^cpu_learner_protocol$' --output-on-failure` | Existing serial learner protocol remains valid | Passed in 1.61 s | node03 build `Testing/Temporary/LastTest.log` | PASS |
| Repeated success (`N=4`) | Initial fixed regression, final fixed regression, 16-rank protocol run, real 16-rank IBAMR smoke | Reject a one-off successful termination | All four terminated normally | Candidate and listed node03 artifacts | PASS |

The fix changes the normal master/environment termination handshake only. The
existing coordinated fatal path still uses `MPI_Abort`; no reset behavior or
recoverable-failure policy was changed by this patch.

## Limitations

This record establishes that a correctly declared distributed environment can
complete the normal Smarties termination path without the demonstrated master
receive deadlock. The real target-case evidence covers one learner rank and one
16-rank, medium-fidelity eel2d smoke environment on the listed node03 stack.

It does not establish training convergence, policy quality, reward quality,
checkpoint restart behavior, multiple concurrent IBAMR environments, GPU or
PyTorch behavior, performance scalability, recoverable physical reset, or
compatibility with another MPI, PETSc, SAMRAI, or IBAMR version.
