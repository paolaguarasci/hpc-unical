#!/bin/bash
# Probe 3: can a server running on a compute node be reached from your machine through the head node?
# The job serves a tiny HTTP page for the allotted time and prints the node and port to use.
#SBATCH --job-name=probe-tunnel
#SBATCH --output=%x-%j.out
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"

PORT=$((20000 + SLURM_JOB_ID % 20000))
NODE=$(hostname)
mkdir -p "$(mktemp -d)" && cd "$(mktemp -d)" && echo "tunnel ok from $NODE" > index.html
echo "node: $NODE  port: $PORT"
echo "from your machine run:  ssh -N -L $PORT:$NODE:$PORT YOUR_LOGIN@hpcgate.unical.it"
echo "then:                    curl http://localhost:$PORT/"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
