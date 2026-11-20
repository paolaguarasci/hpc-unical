#!/bin/bash
# Template for `hpc submit CLASS --time T [--requeue] job.sbatch`.
# Resources, partition and QoS come from `hpc submit`; do not repeat them here.
#SBATCH --job-name=job
#SBATCH --output=%x-%j.out
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"

# Activate the environment that contains the application's dependencies, e.g.:
# source "$(conda info --base)/etc/profile.d/conda.sh" && conda activate pytorch
# or, after `hpc env` (uv env in ~/envs/NAME; NAME defaults to the project directory):
# unset VIRTUAL_ENV; export PYTHONNOUSERSITE=1 PATH="$HOME/envs/NAME/bin:$PATH"

# Preemption sends SIGTERM and allows a 270-second grace period. Bash runs a trap only
# when the foreground command ends, so the application runs in the background and the
# signal is forwarded to it. The application must checkpoint on SIGTERM itself; with
# --requeue the script restarts from the beginning and must reload that checkpoint.
on_term() {
  echo "SIGTERM received: forwarding to the application"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" || true
  exit 143
}
trap on_term TERM

srun python train.py &
child=$!
wait "$child"
