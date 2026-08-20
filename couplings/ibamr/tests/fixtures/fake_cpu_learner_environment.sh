#!/usr/bin/env bash

set -euo pipefail

scenario=${FAKE_CPU_SCENARIO:-valid}
audit_dir=none
restart=none
seed=0
threads=1
updates=1
while (($#)); do
  case $1 in
    --learnerAuditDir) audit_dir=$2; shift 2 ;;
    --restart) restart=$2; shift 2 ;;
    --randSeed) seed=$2; shift 2 ;;
    --nThreads) threads=$2; shift 2 ;;
    --nTrainSteps|--nTrainUpdates) updates=$2; shift 2 ;;
    *) shift ;;
  esac
done

if [[ $scenario == timeout && $restart == none ]]; then
  sleep 3
fi

mkdir -p "$audit_dir"
if [[ $restart == none ]]; then
  mkdir -p "$audit_dir/initial" "$audit_dir/final"
  printf 'initial checkpoint\n' >"$audit_dir/initial/agent_00_net_weights.raw"
  printf 'final checkpoint\n' >"$audit_dir/final/agent_00_net_weights.raw"
  {
    printf 'SMARTIES_NETWORK_AUDIT stage=initialized network=agent_00_network0 step=0 threads=%s precision_bytes=4 params=544 digest=1111111111111111 sum=0 sum_squares=0 max_abs=1 finite=1\n' "$threads"
    limit=$updates
    [[ $scenario == missing_update ]] && limit=$((updates - 1))
    for ((step=1; step<=limit; ++step)); do
      finite=1
      [[ $scenario == nonfinite && $step == 1 ]] && finite=0
      printf 'SMARTIES_NETWORK_AUDIT stage=update network=agent_00_network0 step=%s threads=%s precision_bytes=4 params=544 digest=%016x sum=0 sum_squares=0 max_abs=1 finite=%s\n' "$step" "$threads" "$step" "$finite"
    done
    final_step=$limit
    [[ $scenario == wrong_final_step ]] && final_step=$((updates - 1))
    printf 'SMARTIES_NETWORK_AUDIT stage=final network=agent_00_network0 step=%s threads=%s precision_bytes=4 params=544 digest=2222222222222222 sum=0 sum_squares=0 max_abs=1 finite=1\n' "$final_step" "$threads"
  } >"$audit_dir/learner_audit.log"
else
  if [[ $restart == */initial ]]; then
    digest=1111111111111111
    mse=1.0
    mean_return=-1.0
  else
    digest=2222222222222222
    mse=0.40
    mean_return=-0.40
    [[ $scenario == unchanged ]] && { mse=0.60; mean_return=-0.60; }
    [[ $scenario == four_bad && $threads == 4 ]] && { mse=0.45; mean_return=-0.45; }
    [[ $scenario == four_bad && $threads == 1 ]] && { mse=0.10; mean_return=-0.10; }
    [[ $scenario == checkpoint_mismatch ]] && digest=3333333333333333
  fi
  printf 'SMARTIES_NETWORK_AUDIT stage=restart network=agent_00_network0 step=0 threads=%s precision_bytes=4 params=544 digest=%s sum=0 sum_squares=0 max_abs=1 finite=1\n' "$threads" "$digest" >"$audit_dir/learner_audit.log"
  output_seed=$seed
  [[ $scenario == wrong_seed ]] && output_seed=$((seed + 1))
  episode_limit=8
  [[ $scenario == prefixed_overshoot ]] && episode_limit=9
  for ((episode=1; episode<=episode_limit; ++episode)); do
    if [[ $scenario == prefixed_overshoot ]]; then
      printf '\rCollected %s environment episodes out of 8. ' "$episode"
    fi
    printf 'SMARTIES_SYNTHETIC_EPISODE seed=%s environment=1 episode=%s decisions=32 return=%s mse=%s finite=1\n' \
      "$output_seed" "$episode" "$mean_return" "$mse"
  done
  if [[ $scenario == prefixed_overshoot ]]; then
    summary_decisions=288
  elif [[ $scenario == partial_summary ]]; then
    summary_decisions=286
  else
    summary_decisions=256
  fi
  printf 'SMARTIES_SYNTHETIC_SUMMARY seed=%s environment=1 episodes=8 decisions=%s mean_return=%s action_mse=%s finite=1\n' \
    "$output_seed" "$summary_decisions" "$mean_return" "$mse"
fi

printf 'COUPLING_DRIVER_RETURNED_MPI_ACTIVE\n'
printf 'COUPLING_DRIVER_DESTROYED_MPI_FINALIZED\n'
