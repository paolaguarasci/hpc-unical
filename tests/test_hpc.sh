#!/usr/bin/env bash
# Offline tests for bin/hpc: ssh, rsync and uv are replaced by stubs that log their arguments.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stubs" "$WORK/proj"
export LOG="$WORK/calls.log"
for tool in ssh rsync uv; do
  # STUB_OUT is printed and STUB_EXIT returned, to play the cluster's answer.
  printf '#!/bin/sh\necho "%s $*" >> "$LOG"\nprintf "%%s" "${STUB_OUT:-}"\nexit "${STUB_EXIT:-0}"\n' "$tool" > "$WORK/stubs/$tool"
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

# --- config: HPC_USER and .env loading ---
# Run on an isolated copy of the repo layout (reached directly and through a symlink), so that
# the developer's own .env cannot satisfy the "HPC_USER is required" check.
mkdir -p "$WORK/repo/bin" "$WORK/links"
cp "$ROOT/bin/hpc" "$WORK/repo/bin/hpc"
ln -s "$WORK/repo/bin/hpc" "$WORK/links/hpc"
for entry in "$WORK/repo/bin/hpc" "$WORK/links/hpc"; do
  : > "$LOG"
  (unset HPC_USER; cd "$WORK/proj" && "$entry" queue >/dev/null 2>&1) && fail "HPC_USER required without .env ($entry)" || ok "HPC_USER required without .env ($entry)"
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

run submit cpu --time 00:10:00 job.sbatch -- --array=1-50 --job-name=x
expect_logged "extra sbatch options follow the presets" "--time=00:10:00 --array=1-50 --job-name=x job.sbatch"
run submit cpu --time 00:10:00 job.sbatch -- --mem=8G
expect_logged "extra option comes after the preset it overrides" "--mem=16G --time=00:10:00 --mem=8G job.sbatch"
expect_error "submit with only extra options fails" submit cpu --time 00:10:00 -- --array=1-5

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

# --- tunnel ---
STUB_OUT=ainode02 run tunnel 123 8000
expect_logged "tunnel asks for the node of the job" "squeue -h -j 123 -o %N"
expect_logged "tunnel forwards the port to the node" "ssh -N -o ExitOnForwardFailure=yes -L 8000:ainode02:8000 tester@hpcgate.unical.it"
expect_error "tunnel needs a job with a node" tunnel 123 8000
expect_not_logged "no tunnel without a node" "-L 8000"
STUB_EXIT=1 expect_error "tunnel fails on an unknown job" tunnel 123 8000
expect_error "tunnel rejects non-numeric job" tunnel abc 8000
expect_error "tunnel rejects non-numeric port" tunnel 123 http
expect_error "tunnel needs a port" tunnel 123

# --- wait ---
run wait 123
expect_logged "wait allocates a terminal" "ssh -t tester@hpcgate.unical.it"
expect_logged "wait polls the accounting on the head node" "sacct -X -n -P -j 123 --format=JobID,State,Elapsed,ExitCode"
expect_logged "wait sleeps between polls" "sleep 10"
STUB_EXIT=1 expect_error "wait fails when the job did not complete" wait 123
expect_error "wait rejects non-numeric" wait abc

# --- shell ---
run shell small --time 01:00:00
expect_logged "shell allocates a terminal" "ssh -t tester@hpcgate.unical.it"
expect_logged "shell starts in the project dir" "cd projects/proj && srun --partition=aiq --qos=scavenger"
expect_logged "shell uses the class presets" "--cpus-per-task=3 --mem=64G --time=01:00:00 --gres=gpu:2g.35gb:1 --pty bash -l"
run shell small --booked --time 01:00:00 --mem 16G
expect_logged "shell booked qos" "--qos=gpu_small_reserved"
expect_logged "shell mem override" "--mem=16G"
run shell cpu --time 00:30:00 -- --job-name=dbg
expect_logged "shell extra srun options" "--time=00:30:00 --job-name=dbg --pty bash -l"
expect_error "shell without --time fails" shell tiny
expect_error "shell rejects --requeue" shell tiny --time 00:05:00 --requeue
expect_error "shell takes no script" shell tiny --time 00:05:00 job.sbatch

# --- doctor ---
run doctor && ok "doctor succeeds on a healthy setup" || fail "doctor succeeds on a healthy setup"
expect_logged "doctor checks the connection without prompting" "ssh -o BatchMode=yes -o ConnectTimeout=10 tester@hpcgate.unical.it true"
expect_logged "doctor checks Slurm" "sbatch --version"
expect_logged "doctor checks the project dir" "test -d projects/proj"
grep -q '^ok ' "$WORK/out" && ok "doctor reports passed checks" || fail "doctor reports passed checks"
STUB_EXIT=1 expect_error "doctor fails when the cluster is unreachable" doctor
expect_not_logged "doctor skips the cluster checks when unreachable" "sbatch --version"
grep -q '^FAIL ' "$WORK/out" && ok "doctor reports the failed check" || fail "doctor reports the failed check"

# --- job array tasks (ID_TASK) ---
run logs 10211_2
expect_logged "logs of an array task asks Slurm for its real job ID" "sacct -X -n -P -j 10211_2 --format=JobIDRaw"
run logs 123
expect_not_logged "logs of a plain job needs no lookup" "JobIDRaw"
run cancel 10211_2
expect_logged "cancel accepts an array task" "scancel 10211_2"
run wait 10211_2
expect_logged "wait accepts an array task" "sacct -X -n -P -j 10211_2 --format=JobID,State"
expect_error "logs rejects a malformed task ID" logs 12_
expect_error "logs rejects a non-numeric ID" logs abc

# --- submit / shell --push ---
run submit tiny --time 00:05:00 job.sbatch
expect_not_logged "submit does not push by default" "rsync"
run submit tiny --time 00:05:00 --push job.sbatch
expect_logged "submit --push syncs" "rsync -az"
expect_logged "submit --push still submits" "sbatch --partition=aiq"
[[ $(grep -n rsync "$LOG" | head -n 1 | cut -d: -f1) -lt $(grep -n sbatch "$LOG" | head -n 1 | cut -d: -f1) ]] \
  && ok "submit --push syncs before submitting" || fail "submit --push syncs before submitting"
run shell cpu --time 00:05:00 --push
expect_logged "shell --push syncs" "rsync -az"

# --- info / free ---
run info 123
expect_logged "info runs seff" "seff 123"
expect_error "info rejects non-numeric" info abc
run free
expect_logged "free runs the Python entry point from the repository" "uv run --project $ROOT hpc-free"

echo
[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
