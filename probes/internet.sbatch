#!/bin/bash
# Probe 1: can a compute node reach the internet? (public endpoints only, no credentials sent)
#SBATCH --job-name=probe-internet
#SBATCH --output=%x-%j.out
set -uo pipefail
cd "$SLURM_SUBMIT_DIR"

echo "node: $(hostname)"
for url in \
  https://openrouter.ai/api/v1/models \
  https://pypi.org/simple/pip/ \
  https://conda.anaconda.org/conda-forge/noarch/repodata.json.zst \
  https://huggingface.co; do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -I "$url") || code="curl-failed"
  echo "$code  $url"
done
echo "proxy env: ${https_proxy:-${HTTPS_PROXY:-none}}"
