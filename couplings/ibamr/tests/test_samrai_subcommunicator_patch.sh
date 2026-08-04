#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
patch_file="$repo_root/couplings/ibamr/patches/ibsamrai2-subcommunicator.patch"
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

fail()
{
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$fixture_root/source/hierarchy/boxes" \
  "$fixture_root/source/mesh/clustering" \
  "$fixture_root/source/toolbox/parallel"

cp "${SAMRAI_SOURCE_ROOT:?SAMRAI_SOURCE_ROOT is required}/source/hierarchy/boxes/BinaryTree.C" \
  "$fixture_root/source/hierarchy/boxes/BinaryTree.C"
cp "$SAMRAI_SOURCE_ROOT/source/hierarchy/boxes/BoxComm.C" \
  "$fixture_root/source/hierarchy/boxes/BoxComm.C"
cp "$SAMRAI_SOURCE_ROOT/source/mesh/clustering/AsyncBergerRigoutsosNode.C" \
  "$fixture_root/source/mesh/clustering/AsyncBergerRigoutsosNode.C"
cp "$SAMRAI_SOURCE_ROOT/source/toolbox/parallel/AsyncCommGroup.C" \
  "$fixture_root/source/toolbox/parallel/AsyncCommGroup.C"

patch --dry-run -d "$fixture_root" -p1 -i "$patch_file"
patch -d "$fixture_root" -p1 -i "$patch_file"

for source_file in \
  source/hierarchy/boxes/BinaryTree.C \
  source/hierarchy/boxes/BoxComm.C \
  source/mesh/clustering/AsyncBergerRigoutsosNode.C \
  source/toolbox/parallel/AsyncCommGroup.C; do
  if grep -q 'MPI_COMM_WORLD' "$fixture_root/$source_file"; then
    fail "operational MPI_COMM_WORLD remains in $source_file"
  fi
done

grep -q 'SAMRAI_MPI::getCommunicator()' \
  "$fixture_root/source/hierarchy/boxes/BinaryTree.C" ||
  fail 'BinaryTree does not use the active SAMRAI communicator'
grep -q 'mpi_communicator' \
  "$fixture_root/source/mesh/clustering/AsyncBergerRigoutsosNode.C" ||
  fail 'AsyncBergerRigoutsosNode does not use its supplied communicator'

if patch --dry-run -d "$fixture_root" -p1 -i "$patch_file" >/dev/null 2>&1; then
  fail 'patch applied twice instead of rejecting an already-patched tree'
fi

printf 'SAMRAI subcommunicator patch test passed\n'
