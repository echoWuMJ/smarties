# Smarties-IBAMR eel2d coupling

This directory contains the first executable coupling framework for the IBAMR
0.18.0 `eel2d` example and Smarties. The current executable is deliberately a
lifecycle probe: it advances the real IBAMR hierarchy, checks a one-dimensional
Smarties action, sends one terminal transition, and verifies coordinated MPI
shutdown. It does **not** yet apply the action to the fish or define a meaningful
state, reward, or training problem.

## Fixed process architecture

- `CouplingDriver` is the sole owner of `MPI_Init_thread` and `MPI_Finalize`.
- Smarties borrows `MPI_COMM_WORLD`; it must not finalize caller-owned MPI.
- Smarties learner ranks and IBAMR environment ranks are separate.
- Launches always use `--learnersOnWorkers 0`; IBAMR ranks do not host networks.
- No process is forked after MPI initialization.
- Phase one uses the native CPU Smarties learner. PyTorch is not enabled.

## Build on node3

Upload or extract an immutable source snapshot, then run:

```bash
./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot>
```

The script sources
`/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh` and rejects the build
before CMake unless GCC/G++ 8.5.0, the matching Open MPI wrappers, and the base
IBAMR 0.18.0 environment are active. It then creates or reuses the isolated
dependency overlay
`/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1`. The shared
autoibamr installation is never modified. Python bindings remain disabled.

The overlay is required because the IBSAMRAI2 source bundled on node3 contains
operational `MPI_COMM_WORLD` calls in its box-clustering code. Those calls
deadlock when an IBAMR environment uses a Smarties-created MPI
subcommunicator. The tracked patch redirects them to the active SAMRAI or
caller-supplied communicator. To prepare the overlay explicitly, run:

```bash
./couplings/ibamr/scripts/prepare_node3_ibamr.sh
```

The overlay is content-guarded by the SHA-256 of
`patches/ibsamrai2-subcommunicator.patch`; a stale or partial overlay is not
silently reused.

## One-command smoke run

From the source snapshot:

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --envs 1 \
  --ranks-per-env 1 \
  --fidelity coarse \
  --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1
```

The launcher derives total MPI ranks as:

```text
learner ranks + environments * ranks per environment
```

`--fidelity` accepts `coarse`, `medium`, `fine`, or `curriculum`. Each real run
gets a unique directory below `couplings/ibamr/runs/` containing the rendered
input, copied settings, stdout log, exit code, and a revision/hash manifest.
Use `--dry-run` to validate the environment and print the command without
creating a run directory.

`train` intentionally exits with status 64. It will remain disabled until the
fish control variable, state vector, reward, time horizon, and safety limits are
specified and approved.

## Tests

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
SAMRAI_SOURCE_ROOT=/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBSAMRAI2-2025.10.29 \
  bash couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> --output-on-failure
```

Only results that pass the full admission gate may be promoted into
`experience/verified/`.
