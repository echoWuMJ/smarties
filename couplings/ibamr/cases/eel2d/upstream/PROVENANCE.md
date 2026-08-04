# IBAMR eel2d upstream snapshot provenance

- Snapshot date: 2026-08-04
- Target release: IBAMR 0.18.0
- Verified release marker: `/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBAMR-0.18.0/VERSION`
- Canonical source directory used for verification: `/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBAMR-0.18.0/examples/ConstraintIB/eel2d/`
- License: IBAMR 3-clause BSD license; see the upstream top-level `COPYRIGHT` file.

The local IBAMR workspace reports `0.20.0-pre`, so its kinematics sources were
not labeled as 0.18.0. `IBEELKinematics.h` and `IBEELKinematics.cpp` were copied
from the unpacked 0.18.0 distribution on node3 and then archived locally in this
repository. The local `input2d` and `eel2d.vertex` files were accepted only after
their hashes matched the unpacked 0.18.0 files exactly.

## SHA-256

| File | SHA-256 |
|---|---|
| `IBEELKinematics.h` | `d390a4ad05736f62db427a586adf5907f869aa76871ca976ea796e033ea3e7df` |
| `IBEELKinematics.cpp` | `d1f58a1404a8bc7f9587646972b80eb37d6d424a89a0cc58ddf7284474686625` |
| `eel2d.vertex` | `4fb409f97239120fc05ccd53e067e04177152cf82b6cc0e4275c1bd0f1413542` |
| `input2d.in` | `b78dacc3f50eb67890aa0d6bb758d829e819bcccb296b8ed59dc1476fe6aecd2` |
