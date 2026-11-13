#!/bin/bash
# Smoke-test job: reports its allocation and pauses briefly. Needs no Python environment.
# Resources, partition and QoS come from `hpc submit`.
#SBATCH --job-name=demo
#SBATCH --output=%x-%j.out
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"

printf 'Job: %s\n' "$SLURM_JOB_ID"
printf 'Home: %s\n' "$HOME"
printf 'Working directory: %s\n' "$PWD"
srun bash -c 'hostname; printf "CUDA_VISIBLE_DEVICES=%s\n" "${CUDA_VISIBLE_DEVICES:-unset}"; sleep 5'
