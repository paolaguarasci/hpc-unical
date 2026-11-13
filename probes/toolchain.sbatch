#!/bin/bash -l
# Probe 2: which tools exist for installing the FEM toolchain (FreeCAD, Gmsh, CalculiX) without root?
# Read-only: nothing is installed.
#SBATCH --job-name=probe-toolchain
#SBATCH --output=%x-%j.out
set -uo pipefail
cd "$SLURM_SUBMIT_DIR"

echo "node: $(hostname)"
echo "os: $(. /etc/os-release && echo "$PRETTY_NAME")  glibc: $(ldd --version | head -n 1)"
echo "--- installers and runtimes"
for tool in conda mamba micromamba uv pip python3 apptainer singularity docker podman gmsh ccx FreeCADCmd; do
  printf '%-12s %s\n' "$tool" "$(command -v "$tool" || echo '-')"
done
echo "--- environment modules matching the toolchain"
if command -v module >/dev/null; then
  module avail 2>&1 | grep -i -E 'conda|python|freecad|gmsh|calculix|ccx|cuda|apptainer|singularity' || echo "(none matching)"
else
  echo "module command not available"
fi
echo "--- shared software"
ls /hpc/apps /cm/shared 2>&1 | head -n 40
echo "--- free space in home and /tmp"
df -h "$HOME" /tmp | cat
