#!/usr/bin/env bash
# Live smoke for setup and serve presets. Needs the university VPN and a working
# SSH key; cancels only the jobs it starts. Kept apart from tests/test_hpc.sh,
# which must stay runnable without the cluster.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HPC=${HPC:-"$ROOT/bin/hpc"}
MODEL=${MODEL:-Qwen/Qwen3-0.6B}
CLASS=${CLASS:-tiny}
VLLM_PORT=${VLLM_PORT:-18000}
TB_PORT=${TB_PORT:-16006}
VLLM_TIME=${VLLM_TIME:-00:25:00}
TB_TIME=${TB_TIME:-00:10:00}
SETUP_TIME=${SETUP_TIME:-00:30:00}
READY_TIMEOUT=${READY_TIMEOUT:-900}
TUNNEL_TIMEOUT=${TUNNEL_TIMEOUT:-60}

fails=0
serve_pid=''
our_jobs=()
log=$(mktemp)

ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# Kill a background serve (TERM cancels its Slurm job via serve's EXIT trap) and
# fall back to scancel for any job ID we recorded if the process is already gone.
stop_serve() {
  local pid=${1:-} jid
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  serve_pid=''
  for jid in "${our_jobs[@]+"${our_jobs[@]}"}"; do
    "$HPC" cancel "$jid" >/dev/null 2>&1 || true
  done
  our_jobs=()
}

cleanup() {
  stop_serve "$serve_pid"
  rm -f "$log"
}
trap cleanup EXIT INT TERM

# True when JOB_ID is absent from the live squeue section of `hpc queue` (sacct history ignored).
job_absent_from_queue() {
  local id=$1
  "$HPC" queue 2>/dev/null | awk -v id="$id" '
    /^JobID/ { exit found+0 }
    $1 == id { found=1 }
    END { exit found+0 }
  '
}

# serve prints "ready" before open_tunnel returns; wait until the local port accepts TCP.
wait_local_port() {
  local port=$1 deadline=$((SECONDS + TUNNEL_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      return 1
    fi
    if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Start serve in the background; wait until it prints "ready" and the local tunnel
# accepts connections. Records the Slurm job ID from the "job N runs on" line.
start_serve() {
  local ready_re=$1 port=$2; shift 2
  : > "$log"
  our_jobs=()
  (cd "$ROOT" && exec "$HPC" "$@") >"$log" 2>&1 &
  serve_pid=$!
  local deadline=$((SECONDS + READY_TIMEOUT)) jid
  while (( SECONDS < deadline )); do
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      wait "$serve_pid" 2>/dev/null || true
      serve_pid=''
      echo "---- serve output ----"; cat "$log"; echo "----"
      return 1
    fi
    # No \b: BSD sed (macOS) does not treat it as a word boundary.
    jid=$(sed -nE 's/.*job ([0-9]+) runs on.*/\1/p' "$log" | tail -n1)
    [[ -n ${jid:-} && ${#our_jobs[@]} -eq 0 ]] && our_jobs+=("$jid")
    if grep -qE "$ready_re" "$log"; then
      if wait_local_port "$port"; then
        return 0
      fi
      echo "---- serve output (tunnel did not open) ----"; cat "$log"; echo "----"
      stop_serve "$serve_pid"
      return 1
    fi
    sleep 2
  done
  echo "---- serve output (timeout) ----"; cat "$log"; echo "----"
  stop_serve "$serve_pid"
  return 1
}

echo "== live smoke (VPN required): setup + serve vllm + serve tensorboard"
echo "    model=$MODEL class=$CLASS vllm_port=$VLLM_PORT tb_port=$TB_PORT"

# --- doctor: VPN + SSH + Slurm ---
if out=$("$HPC" doctor 2>&1); then
  ok "doctor passes"
else
  fail "doctor passes"
  echo "$out"
  echo "Connect the university VPN and retry."
  exit 1
fi

# --- setup: ensure vllm and tensorboard environments exist ---
echo "== hpc setup vllm tensorboard --time $SETUP_TIME"
if out=$(cd "$ROOT" && "$HPC" setup vllm tensorboard --time "$SETUP_TIME" 2>&1); then
  echo "$out" | grep -E 'ok   - (vllm|tensorboard)' >/dev/null \
    && ok "setup reports ok for vllm and tensorboard" \
    || { fail "setup reports ok for vllm and tensorboard"; echo "$out"; }
else
  fail "setup vllm tensorboard"
  echo "$out"
fi

# --- serve vllm: wait for ready, curl /v1/models, release the job ---
echo "== hpc serve $CLASS --time $VLLM_TIME vllm $MODEL --port $VLLM_PORT"
if start_serve "ready on port .* open http://localhost:$VLLM_PORT" "$VLLM_PORT" \
    serve "$CLASS" --time "$VLLM_TIME" vllm "$MODEL" --port "$VLLM_PORT"; then
  ok "serve vllm prints ready and the tunnel listens"
  if body=$(curl -fsS --max-time 30 "http://127.0.0.1:$VLLM_PORT/v1/models" 2>&1); then
    echo "$body" | grep -qF "$MODEL" \
      && ok "curl /v1/models returns $MODEL" \
      || { fail "curl /v1/models returns $MODEL"; echo "$body"; }
  else
    fail "curl /v1/models"
    echo "$body"
  fi
  jid=${our_jobs[0]:-}
  stop_serve "$serve_pid"
  if [[ -n $jid ]]; then
    gone=0
    for _ in $(seq 30); do
      if job_absent_from_queue "$jid"; then gone=1; break; fi
      sleep 1
    done
    [[ $gone -eq 1 ]] && ok "serve vllm job $jid is gone after TERM" \
      || fail "serve vllm job $jid is gone after TERM"
  else
    fail "serve vllm recorded a job ID"
  fi
else
  fail "serve vllm prints ready and the tunnel listens"
fi

# --- serve tensorboard on a cpu slice ---
echo "== hpc serve cpu --time $TB_TIME tensorboard --port $TB_PORT"
if start_serve "ready on port .* open http://localhost:$TB_PORT" "$TB_PORT" \
    serve cpu --time "$TB_TIME" tensorboard --port "$TB_PORT"; then
  ok "serve tensorboard prints ready and the tunnel listens"
  if body=$(curl -fsS --max-time 30 "http://127.0.0.1:$TB_PORT/" 2>&1); then
    echo "$body" | grep -qi 'tensorboard' \
      && ok "curl tensorboard returns its UI" \
      || { fail "curl tensorboard returns its UI"; echo "$body" | head -n 20; }
  else
    fail "curl tensorboard"
    echo "$body"
  fi
  jid=${our_jobs[0]:-}
  stop_serve "$serve_pid"
  if [[ -n $jid ]]; then
    gone=0
    for _ in $(seq 30); do
      if job_absent_from_queue "$jid"; then gone=1; break; fi
      sleep 1
    done
    [[ $gone -eq 1 ]] && ok "serve tensorboard job $jid is gone after TERM" \
      || fail "serve tensorboard job $jid is gone after TERM"
  else
    fail "serve tensorboard recorded a job ID"
  fi
else
  fail "serve tensorboard prints ready and the tunnel listens"
fi

echo
if [[ $fails -eq 0 ]]; then
  echo "all passed"
  exit 0
fi
echo "$fails failed"
exit 1
