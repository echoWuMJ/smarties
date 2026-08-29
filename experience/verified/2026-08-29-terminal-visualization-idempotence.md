# Verified terminal visualization idempotence

- Status: verified
- Verified on: 2026-08-29 (Asia/Shanghai)
- Scope: IBAMR 0.18.0 eel2d `EelEnvironment` terminal visualization on node03; the original symptom was captured in a 16-rank 10 s evaluation run and the focused fix was verified with a one-rank real IBAMR regression
- Parent revision reproducing the defect: `9fd41767d326a76017b0b8b4e88db93700028484`
- Fix revision: `d9af395df2ee80e9dcc98c345e11140ed3dbce06`
- Evidence candidate: `.artifacts/ibamr-smarties-investigations/terminal-visualization/candidate.md`
- Reviewer: fresh command rerun and artifact inspection by the primary Codex agent

## Environment

- Host: `node03`
- OS/kernel: CentOS Linux 7, Linux `3.10.0-1160.108.1.el7.x86_64`
- CPU: two Intel Xeon Platinum 8179M sockets, 26 physical cores per socket, two threads per core
- Compiler: GCC/G++ 8.5.0
- MPI: Open MPI 5.0.9
- PETSc: 3.23.3
- IBAMR: 0.18.0 with the existing SAMRAI subcommunicator overlay
- Smarties neural-network backend: native CPU; it is not exercised by the focused environment test

## Topology, inputs, and commands

The original run used 17 MPI ranks: one learner and one 16-rank IBAMR
environment, with one learner thread. Its frozen `manifest.txt`, `input2d`,
`task.conf`, and `settings.json` are in the listed run directory. The exact
launch command was:

```text
mpiexec -n 17 /data2/mjwu/local/coupling-build/smarties-distributed-shutdown-fix-20260824/couplings/ibamr/ibamr_eel2d_smoke --nMasters 1 --nThreads 1 --nEnvironments 1 --workerProcessesPerEnv 16 --learnersOnWorkers 0 --nTrainSteps 0 --nTrainUpdates 0 --logAllSamples 1 --restart /data2/mjwu/local/coupling-src/smarties-ibamr-20260823T154940Z-95834f4cad44/couplings/ibamr/runs/eel2d-20260824T082928Z-95834f4cad44-21851/learner-audit/final --setupFolder . --input-file input2d --eel-mode speed-tracking --task-file task.conf --learnerAuditDir /data2/mjwu/local/coupling-src/smarties-distributed-shutdown-fix-a4d0d91ad653/couplings/ibamr/runs/eel2d-20260824T143737Z-a4d0d91ad653-19731/learner-audit --nEvalEpisodes 40
```

The focused test used one MPI rank, the official 2932-point `eel2d.vertex`,
medium fidelity, `END_TIME=0.0001`, and visualization interval 1. CTest resolves
its command to:

```text
/data2/mjwu/local/openmpi/bin/mpiexec -n 1 /data2/mjwu/local/coupling-build/smarties-distributed-shutdown-fix-20260824/couplings/ibamr/tests/eel_terminal_visualization input2d
```

## Problem and original symptom

The 16-rank 10 s evaluation reached physical time 10 and wrote visualization
step 100000, but exited with status 255. `stdout.log` records
`time step number: 100000 is <= last time step number: 100000`, followed by
`MPI_ABORT`. `processes-after.txt` is empty.

The focused regression reproduced the same failure at step 1. It advances a
real eel2d environment to `END_TIME=0.0001`, where `advanceOneStep()` writes the
last step, and then invokes `writeVisualizationSnapshot()` as the Smarties
adapter does at termination. The parent implementation failed in 1.36 s with
`time step number: 1 is <= last time step number: 1`.

## Demonstrated root cause

`advanceOneStep()` writes visualization data whenever the current iteration is
a configured dump point or the last IBAMR step. The adapter independently asks
the environment for a terminal visualization snapshot after the final Smarties
exchange. When physical `END_TIME` is itself the terminal boundary, both paths
passed the same iteration to `VisItDataWriter`, which requires strictly
increasing iteration numbers. The deterministic one-step RED test distinguishes
this output-layer duplicate from slow time stepping, lost MPI messages, or the
distributed-environment shutdown protocol.

## Resolution

`EelEnvironment` now routes initial, periodic/last-step, and explicit terminal
visualization through one helper. The helper records the last successfully
written visualization iteration and returns without writing when that same
iteration is requested again. A terminal request at an iteration not already
written is still emitted.

## Verification matrix

| Check | Command/input | Expected | Actual | Artifact | Result |
|---|---|---|---|---|---|
| Original 10 s symptom | Existing 16-rank evaluation, `END_TIME=10` | Capture the observed terminal failure | Reached time 10, then duplicate step 100000 caused MPI abort; exit 255 | `/data2/mjwu/local/coupling-src/smarties-distributed-shutdown-fix-a4d0d91ad653/couplings/ibamr/runs/eel2d-20260824T143737Z-a4d0d91ad653-19731/` | PASS |
| Focused RED | Parent revision plus new test; `ctest -R '^eel_terminal_visualization$' --output-on-failure` | Old code rejects the duplicate terminal write | Failed in 1.36 s with step 1 `<=` step 1 | `couplings/ibamr/tests/eel-terminal-visualization-red/` in the node03 build | PASS |
| Focused GREEN, repeated (`N=2`) | Fix revision; same CTest, then the three-test focused suite | Both runs exit 0 | Passed in 1.02 s and 1.03 s | node03 `Testing/Temporary/LastTest.log` and `couplings/ibamr/tests/eel-terminal-visualization/` | PASS |
| Output identity | Count step 1 in `dumps.visit` and `lag_data.visit` | One Eulerian and one Lagrangian step-1 entry | Both counts were exactly 1 | Fixed test run directory | PASS |
| Clean shutdown | `pgrep -ax eel_terminal_vi` after the run | No residual test process | No output | Fresh node03 process inspection | PASS |
| Neighboring environment paths | `ctest -R '^(eel_environment_smoke|eel_environment_control|eel_terminal_visualization)$' --output-on-failure` | Ordinary advancement, control, and terminal output remain valid | 3/3 passed in 2.86 s | node03 `Testing/Temporary/LastTest.log` | PASS |

No reset behavior is defined or changed by this output-only patch. The original
fatal path remains an MPI abort when a writer detects an invalid sequence.

## Limitations

The fix was not followed by another 10 s, 16-rank evaluation because the
one-step test reproduces the same writer invariant directly. The fixed-run
evidence covers one real IBAMR rank and VisIt/Silo visualization only. It does
not establish multi-rank performance, restart or postprocessing idempotence,
policy quality, reward calibration, training convergence, PyTorch/CUDA
behavior, or compatibility with another IBAMR/SAMRAI version.
