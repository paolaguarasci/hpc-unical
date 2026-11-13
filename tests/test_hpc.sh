#!/usr/bin/env bash
# Offline tests for bin/hpc: ssh, rsync and uv are replaced by stubs that log their arguments.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stubs" "$WORK/proj"
export LOG="$WORK/calls.log"
for tool in ssh rsync uv; do
  printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$tool" > "$WORK/stubs/$tool"
  chmod +x "$WORK/stubs/$tool"
done
export PATH="$WORK/stubs:$PATH"
export HPC_USER=tester

fails=0
run() { : > "$LOG"; (cd "$WORK/proj" && "$ROOT/bin/hpc" "$@") > "$WORK/out" 2>&1; }
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect_logged() { grep -qF -- "$2" "$LOG" && ok "$1" || { fail "$1 (missing: $2)"; cat "$LOG"; }; }
expect_not_logged() { grep -qF -- "$2" "$LOG" && fail "$1 (unexpected: $2)" || ok "$1"; }
expect_error() { shift_name=$1; shift; if run "$@"; then fail "$shift_name (exit 0)"; else ok "$shift_name"; fi; }

# --- config ---
(unset HPC_USER; cd "$WORK/proj" && "$ROOT/bin/hpc" queue >/dev/null 2>&1) && fail "HPC_USER required" || ok "HPC_USER required"

# --- .env loading (isolated copy of the repo layout, reached directly and through a symlink) ---
mkdir -p "$WORK/repo/bin" "$WORK/links"
cp "$ROOT/bin/hpc" "$WORK/repo/bin/hpc"
ln -s "$WORK/repo/bin/hpc" "$WORK/links/hpc"
for entry in "$WORK/repo/bin/hpc" "$WORK/links/hpc"; do
  : > "$LOG"
  (unset HPC_USER; cd "$WORK/proj" && "$entry" queue >/dev/null 2>&1) && fail ".env missing fails ($entry)" || ok ".env missing fails ($entry)"
  echo 'HPC_USER=fromenv' > "$WORK/repo/.env"
  : > "$LOG"
  (unset HPC_USER; cd "$WORK/proj" && "$entry" queue >/dev/null 2>&1)
  expect_logged ".env user used ($entry)" "fromenv@hpcgate.unical.it"
  : > "$LOG"
  (cd "$WORK/proj" && HPC_USER=explicit "$entry" queue >/dev/null 2>&1)
  expect_logged "environment beats .env ($entry)" "explicit@hpcgate.unical.it"
  rm "$WORK/repo/.env"
done

# --- submit ---
run submit tiny --time 00:05:00 job.sbatch
expect_logged "tiny targets gate host" "tester@hpcgate.unical.it"
expect_logged "tiny cds into project dir" "cd projects/proj"
expect_logged "tiny qos" "--qos=scavenger"
expect_logged "tiny gres" "--gres=gpu:1g.35gb:1"
expect_logged "tiny cpus" "--cpus-per-task=2"
expect_logged "tiny mem" "--mem=32G"
expect_logged "tiny time" "--time=00:05:00"
expect_logged "tiny partition" "--partition=aiq"
expect_logged "tiny script" "job.sbatch"
expect_not_logged "tiny not requeue" "--requeue"

run submit small --booked --time 01:00:00 job.sbatch
expect_logged "booked qos" "--qos=gpu_small_reserved"
expect_logged "small gres" "--gres=gpu:2g.35gb:1"
expect_logged "small cpus" "--cpus-per-task=3"
expect_logged "small mem" "--mem=64G"

run submit large --time 01:00:00 job.sbatch
expect_logged "large gres" "--gres=gpu:7g.141gb:1"
expect_logged "large mem" "--mem=240G"
run submit medium --time 01:00:00 job.sbatch
expect_logged "medium gres" "--gres=gpu:4g.71gb:1"

run submit cpu --time 00:10:00 job.sbatch
expect_not_logged "cpu has no gres" "--gres"
expect_logged "cpu mem" "--mem=16G"

run submit tiny --time 00:05:00 --requeue --cpus 4 --mem 48G job.sbatch
expect_logged "requeue flag" "--requeue"
expect_logged "cpus override" "--cpus-per-task=4"
expect_logged "mem override" "--mem=48G"

expect_error "submit without --time fails" submit tiny job.sbatch
expect_error "submit without script fails" submit tiny --time 00:05:00
expect_error "unknown class fails" submit huge --time 00:05:00 job.sbatch
expect_error "cpu cannot be booked" submit cpu --booked --time 00:05:00 job.sbatch

# --- queue / qos ---
run queue
expect_logged "queue squeue" "squeue -u"
expect_logged "queue sacct" "sacct"
expect_not_logged "queue runs once" "watch"
run queue -w
expect_logged "queue -w allocates a terminal" "ssh -t tester@hpcgate.unical.it"
expect_logged "queue -w default interval" "watch -n 10 "
expect_logged "queue -w watches squeue" "squeue -u"
expect_logged "queue -w watches sacct" "sacct"
run queue -w 3
expect_logged "queue -w custom interval" "watch -n 3 "
expect_error "queue -w rejects non-numeric interval" queue -w abc
expect_error "queue rejects unknown option" queue -x
run top
expect_logged "top runs the application from the repository" "uv run --project $ROOT hpc-top"
run qos
expect_logged "qos sacctmgr" "sacctmgr"

# --- sync ---
run push
expect_logged "push creates remote dir" "mkdir -p projects/proj"
expect_logged "push rsync target" "tester@hpcgate.unical.it:projects/proj/"
expect_logged "push respects gitignore" ".gitignore"
expect_not_logged "push never deletes" "--delete"
run pull results.csv sub/log.txt
expect_logged "pull relative path" "tester@hpcgate.unical.it:projects/proj/./results.csv"
expect_logged "pull second path" "tester@hpcgate.unical.it:projects/proj/./sub/log.txt"
expect_error "pull without path fails" pull

# --- logs / cancel ---
run logs 123
expect_logged "logs by id" "*-123.out"
run logs
expect_logged "logs latest" "ls -t *.out"
run cancel 123
expect_logged "cancel" "scancel 123"
expect_error "cancel rejects non-numeric" cancel abc
expect_error "unknown command fails" bogus

echo
[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
