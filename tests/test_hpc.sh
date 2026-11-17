#!/usr/bin/env bash
# Offline tests for bin/hpc: ssh, rsync and uv are replaced by stubs that log their arguments.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stubs" "$WORK/proj"
export LOG="$WORK/calls.log"
for tool in ssh rsync uv osascript; do
  # STUB_OUT is printed and STUB_EXIT returned, to play the cluster's answer; a call to sbatch
  # prints STUB_SBATCH instead when it is set.
  printf '#!/bin/sh\necho "%s $*" >> "$LOG"\ncase "$*" in *sbatch*) printf "%%s" "${STUB_SBATCH:-${STUB_OUT:-}}" ;; *) printf "%%s" "${STUB_OUT:-}" ;; esac\nexit "${STUB_EXIT:-0}"\n' "$tool" > "$WORK/stubs/$tool"
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
expect_logged "queue -w allocates a terminal" "ssh -o ControlPath=none -t tester@hpcgate.unical.it"
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

# --- setup: check and install ollama and ComfyUI on a cpu node ---
run setup
expect_logged "setup runs srun on a cpu node, not on the head node" "srun --partition=aiq --qos=scavenger --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=16G --time=01:00:00 bash -c"
expect_not_logged "setup asks for no GPU" "--gres"
expect_logged "setup handles both components by default" "hpc-setup ollama comfy"
expect_logged "setup downloads ollama" "ollama-linux-amd64.tar.zst"
expect_logged "setup installs ComfyUI with comfy-cli" "comfy-cli"
expect_logged "setup keeps the install out of the user site" "PYTHONNOUSERSITE=1"
expect_logged "setup points comfy-cli at its environment" "CONDA_PREFIX="
expect_logged "setup installs ComfyUI in ~/comfy/ComfyUI" "--workspace \"\$ws/ComfyUI\""
run setup comfy --time 00:20:00
expect_logged "setup takes one component" "hpc-setup comfy"
expect_logged "setup --time overrides the default" "--time=00:20:00"
expect_error "setup rejects an unknown component" setup nginx
expect_error "setup rejects an unknown option" setup --gpu
STUB_EXIT=1 expect_error "setup fails when the cluster reports a failure" setup ollama
# The script itself, with the network replaced by a failing curl: it must report FAIL and exit non-zero,
# and must leave an installed ollama alone.
mkdir -p "$WORK/fakehome/.local/bin" "$WORK/nonet"
printf '#!/bin/sh\nexit 22\n' > "$WORK/nonet/curl"; chmod +x "$WORK/nonet/curl"
script=$(sed -n "/^SETUP_SCRIPT=\$(cat <<'EOF'/,/^EOF$/p" "$ROOT/bin/hpc" | sed '1d;$d')
out=$(HOME="$WORK/fakehome" PATH="$WORK/nonet:$PATH" bash -c "$script" x ollama comfy 2>&1); code=$?
[[ $code -ne 0 && $out == *"FAIL - ollama: this node cannot reach ollama.com"* && $out == *"FAIL - comfy: this node cannot reach pypi.org"* ]] && ok "setup script fails explicitly without network" || { fail "setup script fails explicitly without network"; echo "$out"; }
printf '#!/bin/sh\n' > "$WORK/fakehome/.local/bin/ollama"; chmod +x "$WORK/fakehome/.local/bin/ollama"
out=$(HOME="$WORK/fakehome" PATH="$WORK/nonet:$PATH" bash -c "$script" x ollama 2>&1); code=$?
[[ $code -eq 0 && $out == "ok   - ollama is installed"* ]] && ok "setup script leaves an installed ollama alone" || { fail "setup script leaves an installed ollama alone"; echo "$out"; }

# ComfyUI present but the environment without PyTorch (a past install that went to ~/.local): the script
# must refuse, not report ok and not reinstall over it.
mkdir -p "$WORK/h2/comfy/ComfyUI" "$WORK/h2/envs/comfy/bin" "$WORK/yes"
printf '#!/bin/sh\nexit 0\n' > "$WORK/yes/curl"; chmod +x "$WORK/yes/curl"
printf '#!/bin/sh\n' > "$WORK/h2/envs/comfy/bin/comfy-cli"; printf '#!/bin/sh\nexit 1\n' > "$WORK/h2/envs/comfy/bin/python"
chmod +x "$WORK/h2/envs/comfy/bin/"*
out=$(HOME="$WORK/h2" PATH="$WORK/yes:$PATH" bash -c "$script" x comfy 2>&1); code=$?
[[ $code -ne 0 && $out == *"has no PyTorch"* ]] && ok "setup refuses a ComfyUI whose environment has no PyTorch" || { fail "setup refuses a ComfyUI whose environment has no PyTorch"; echo "$out"; }

# --- model: download a model on the cluster, in a cpu job ---
run model comfy "https://huggingface.co/x/y/resolve/main/file.safetensors?download=true" --to loras
expect_logged "model runs in a cpu job on the compute node" "srun --partition=aiq --qos=scavenger --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=16G --time=01:00:00 bash -c"
expect_not_logged "model asks for no GPU" "--gres"
expect_logged "model passes the URL, the folder and the file name from the URL" "hpc-model comfy"
expect_logged "model derives the file name without the query" "loras file.safetensors"
expect_logged "model uses comfy-cli to download" "comfy-cli"
run model comfy "https://example.org/a/b.bin" --to vae --filename other.safetensors --time 02:00:00
expect_logged "model --filename overrides the name" "https://example.org/a/b.bin vae other.safetensors"
expect_logged "model --time overrides the default" "--time=02:00:00"
run model ollama llama3.2:1b
expect_logged "model pulls an Ollama model by name" "hpc-model ollama llama3.2:1b"
expect_error "model needs a kind" model
expect_error "model rejects an unknown kind" model nginx x
expect_error "model comfy needs --to" model comfy https://example.org/a.bin
expect_error "model comfy rejects a path as --to" model comfy https://example.org/a.bin --to ../x
expect_error "model comfy needs https" model comfy http://example.org/a.bin --to vae
expect_error "model comfy rejects an unsafe file name" model comfy "https://example.org/a;b" --to vae
expect_error "model needs exactly one model" model ollama a b
expect_error "model ollama takes no --to" model ollama llama3 --to vae
expect_error "model ollama rejects an invalid name" model ollama 'a b;c'
STUB_EXIT=1 expect_error "model fails when the cluster reports a failure" model ollama llama3
# The script itself, run locally with a fake curl, df-independent sizes and a fake comfy-cli.
mscript=$(sed -n "/^MODEL_SCRIPT=\$(cat <<'EOF'/,/^EOF$/p" "$ROOT/bin/hpc" | sed '1d;$d')
mh="$WORK/mh"; mkdir -p "$mh/comfy/ComfyUI/models/loras" "$mh/envs/comfy/bin" "$WORK/cs"
cat > "$WORK/cs/curl" <<'CURLEOF'
#!/bin/sh
printf 'HTTP/2 302\r\ncontent-length: 5\r\n\r\nHTTP/2 200\r\nContent-Length: %s\r\n\r\n' "${STUB_SIZE:-10}"
CURLEOF
cat > "$mh/envs/comfy/bin/comfy-cli" <<'CLIEOF'
#!/bin/sh
echo "comfy-cli $*" >> "$LOG"
rel=; fn=
while [ $# -gt 0 ]; do
  case $1 in --relative-path) rel=$2 ;; --filename) fn=$2 ;; esac
  shift
done
[ "$fn" = "${STUB_FAIL:-}" ] && exit 1
head -c "${STUB_SIZE:-10}" /dev/zero > "$HOME/comfy/ComfyUI/$rel/$fn"
CLIEOF
chmod +x "$WORK/cs/curl" "$mh/envs/comfy/bin/comfy-cli"
URL=https://example.org/m.bin
: > "$LOG"; out=$(HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy $URL loras m.bin 2>&1); code=$?
[[ $code -eq 0 && $out == *"ok   - m.bin is in models/loras"* ]] && grep -qF -- "model download --url $URL --relative-path models/loras --filename m.bin" "$LOG" && ok "model script downloads through comfy-cli into the right folder" || { fail "model script downloads through comfy-cli into the right folder"; echo "$out"; cat "$LOG"; }
: > "$LOG"; out=$(HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy $URL loras m.bin 2>&1); code=$?
[[ $code -eq 0 && $out == *"already in models/loras"* && ! -s "$LOG" ]] && ok "model script skips a file of the announced size" || { fail "model script skips a file of the announced size"; echo "$out"; }
out=$(STUB_SIZE=11 HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy $URL loras m.bin 2>&1); code=$?
[[ $code -ne 0 && $out == *"exists with a different size"* ]] && ok "model script never overwrites a file of another size" || { fail "model script never overwrites a file of another size"; echo "$out"; }
rm "$mh/comfy/ComfyUI/models/loras/m.bin"
out=$(STUB_SIZE=99999999999999999 HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy $URL loras m.bin 2>&1); code=$?
[[ $code -ne 0 && $out == *"not enough space"* && ! -e "$mh/comfy/ComfyUI/models/loras/m.bin" ]] && ok "model script refuses a download larger than the free space" || { fail "model script refuses a download larger than the free space"; echo "$out"; }
out=$(HOME="$WORK/empty-home" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy $URL loras m.bin 2>&1); code=$?
[[ $code -ne 0 && $out == *"run hpc setup comfy"* ]] && ok "model script asks for hpc setup when ComfyUI is missing" || { fail "model script asks for hpc setup when ComfyUI is missing"; echo "$out"; }
out=$(HOME="$WORK/empty-home" bash -c "$mscript" x ollama llama3 2>&1); code=$?
[[ $code -ne 0 && $out == *"run hpc setup ollama"* ]] && ok "model script asks for hpc setup when ollama is missing" || { fail "model script asks for hpc setup when ollama is missing"; echo "$out"; }

# --- model list: the catalogue and what is present, read on the head node ---
run model list
expect_logged "model list runs a script on the head node, not in a job" "PYTHONNOUSERSITE=1 \"\$py\" -"
expect_not_logged "model list starts no job" "srun"
expect_logged "model list passes target, type, text and urls" "- all '' '' 0"
run model list comfy --type lora --filter flux --urls
expect_logged "model list passes its filters" "- comfy lora flux 1"
run model list ollama
expect_logged "model list can be limited to Ollama" "- ollama '' '' 0"
expect_error "model list rejects an unknown option" model list --bogus
expect_error "model list rejects --type for Ollama" model list ollama --type lora
run model comfy "https://example.org/a.bin" --to diffusion_models/FLUX1
expect_logged "model comfy accepts a sub-folder" "hpc-model comfy"
expect_error "model comfy rejects .. in --to" model comfy https://example.org/a.bin --to a/../b
expect_error "model comfy rejects an absolute --to" model comfy https://example.org/a.bin --to /etc
expect_error "model comfy rejects a hidden folder in --to" model comfy https://example.org/a.bin --to .ssh
# The Python script, run locally on a fake home, a fake catalogue and a fake Ollama store.
lh="$WORK/lh"; mkdir -p "$lh/comfy/ComfyUI/models/loras" "$lh/comfy/ComfyUI/models/diffusion_models/FLUX1" "$WORK/fake/comfyui_manager"
printf 'x' > "$lh/comfy/ComfyUI/models/loras/have.safetensors"
printf 'x' > "$lh/comfy/ComfyUI/models/diffusion_models/FLUX1/flux.safetensors"
cat > "$WORK/fake/comfyui_manager/__init__.py" <<'PYEOF2'
PYEOF2
cat > "$WORK/fake/comfyui_manager/model-list.json" <<'JSONEOF'
{"models": [
 {"name": "Have LoRA", "type": "lora", "base": "SDXL", "save_path": "loras", "filename": "have.safetensors", "url": "https://e.org/have", "size": "1.0GB"},
 {"name": "Missing LoRA", "type": "lora", "base": "SD1.5", "save_path": "loras", "filename": "miss.safetensors", "url": "https://e.org/miss", "size": "2.0GB"},
 {"name": "Flux", "type": "diffusion_model", "base": "FLUX.1", "save_path": "diffusion_models/FLUX1", "filename": "flux.safetensors", "url": "https://e.org/flux", "size": "20GB"},
 {"name": "A VAE", "type": "VAE", "base": "SD", "save_path": "default", "filename": "vae.pt", "url": "https://e.org/vae", "size": "300MB"}
]}
JSONEOF
mkdir -p "$lh/.ollama/models/manifests/registry.ollama.ai/library/llama3" "$lh/.ollama/models/manifests/registry.ollama.ai/someone/tool"
echo '{"config": {"size": 10}, "layers": [{"size": 1073741814}]}' > "$lh/.ollama/models/manifests/registry.ollama.ai/library/llama3/8b"
echo '{"config": {"size": 1}, "layers": [{"size": 2}]}' > "$lh/.ollama/models/manifests/registry.ollama.ai/someone/tool/latest"
mlist() { HOME="$lh" PYTHONPATH="$WORK/fake" python3 "$ROOT/remote/model_list.py" "$@" 2>&1; }
out=$(mlist all "" "" 0)
[[ $out == *"[x]"*"Have LoRA"* && $out == *"[ ]"*"Missing LoRA"* ]] && ok "model list marks the models already present" || { fail "model list marks the models already present"; echo "$out"; }
[[ $out == *"[x]"*"diffusion_models/FLUX1"*"Flux"* ]] && ok "model list checks the file in the sub-folder of the catalogue" || { fail "model list checks the file in the sub-folder of the catalogue"; echo "$out"; }
[[ $out == *"4 models, 2 present"* ]] && ok "model list counts the models and the present ones" || { fail "model list counts the models and the present ones"; echo "$out"; }
[[ $out == *"upscale_models"* || $out == *"vae"*"A VAE"* ]] && ok "model list resolves the default folder by type" || { fail "model list resolves the default folder by type"; echo "$out"; }
[[ $out == *"1.0 GB"*"llama3:8b"* && $out == *"someone/tool:latest"* && $out == *"2 models installed"* ]] && ok "model list shows the Ollama models installed, with namespace and size" || { fail "model list shows the Ollama models installed, with namespace and size"; echo "$out"; }
out=$(mlist comfy lora "" 0)
[[ $out == *"2 models, 1 present"* && $out != *"Flux"* ]] && ok "model list --type keeps one catalogue type" || { fail "model list --type keeps one catalogue type"; echo "$out"; }
out=$(mlist comfy "" "FLUX" 0)
[[ $out == *"1 models, 1 present"* ]] && ok "model list --filter is case-insensitive and searches name, base and file" || { fail "model list --filter is case-insensitive and searches name, base and file"; echo "$out"; }
out=$(mlist comfy "" "" 1)
[[ $out == *"https://e.org/miss"* ]] && ok "model list --urls adds the download URL" || { fail "model list --urls adds the download URL"; echo "$out"; }
out=$(HOME="$WORK/empty-home" python3 "$ROOT/remote/model_list.py" comfy "" "" 0 2>&1); code=$?
[[ $code -ne 0 && $out == *"run hpc setup comfy"* ]] && ok "model list asks for hpc setup when ComfyUI-Manager is missing" || { fail "model list asks for hpc setup when ComfyUI-Manager is missing"; echo "$out"; }
out=$(HOME="$WORK/empty-home" python3 "$ROOT/remote/model_list.py" ollama "" "" 0 2>&1); code=$?
[[ $code -eq 0 && $out == *"0 models installed"* ]] && ok "model list handles an empty Ollama store" || { fail "model list handles an empty Ollama store"; echo "$out"; }

# --- a script edited while it runs must not be misread (bash reads it as it goes) ---
mkdir -p "$WORK/mut/bin" "$WORK/mut/slow"
cp "$ROOT/bin/hpc" "$WORK/mut/bin/hpc"
printf '#!/bin/sh\nsleep 2\n' > "$WORK/mut/slow/ssh"; chmod +x "$WORK/mut/slow/ssh"
(cd "$WORK/proj" && PATH="$WORK/mut/slow:$PATH" "$WORK/mut/bin/hpc" queue > "$WORK/mut/out" 2>&1; echo $? > "$WORK/mut/code") &
sleep 1
# Rewrite the same file in place, longer, like an editor saving it: every offset below the change moves.
python3 - "$WORK/mut/bin/hpc" <<'PYEOF2'
import sys
lines = open(sys.argv[1]).read().split("\n")
lines.insert(3, "# " + "inserted while the script runs " * 8)
open(sys.argv[1], "w").write("\n".join(lines))
PYEOF2
wait
[[ $(cat "$WORK/mut/code") -eq 0 && ! -s "$WORK/mut/out" ]] && ok "a script rewritten while it runs does not run anything after its last command" || { fail "a script rewritten while it runs does not run anything after its last command"; cat "$WORK/mut/out"; }

# --- model: several URLs in one command ---
U1=https://example.org/a.safetensors; U2=https://example.org/b.safetensors; U3=https://example.org/c.safetensors
run model comfy --to loras $U1 --to vae $U2 $U3 --to text_encoders
expect_logged "model sends one job for all the URLs" "hpc-model comfy"
expect_logged "model gives a URL the --to before it" "$U1 loras a.safetensors"
expect_logged "model keeps the --to for the URLs that follow it" "$U2 vae b.safetensors $U3 vae c.safetensors"
run model comfy $U1 --to loras $U2
expect_logged "model gives a URL before any --to the first --to" "$U1 loras a.safetensors $U2 loras b.safetensors"
expect_error "model rejects --filename with several URLs" model comfy --to vae $U1 $U2 --filename x.bin
expect_error "model rejects a URL that is not https among several" model comfy --to vae $U1 http://example.org/x.bin
expect_error "model rejects a bad --to for the URLs that follow it" model comfy --to vae $U1 --to ../x $U2
run model comfy --to vae $U1 --to loras $U2
expect_logged "model sends a different folder per URL" "$U2 loras b.safetensors"
# The script with several models: one present, one new, one failing, all in one run.
mkdir -p "$mh/comfy/ComfyUI/models/vae"
rm -f "$mh/comfy/ComfyUI/models/loras/"* "$mh/comfy/ComfyUI/models/vae/"*
head -c 10 /dev/zero > "$mh/comfy/ComfyUI/models/vae/have.bin"
: > "$LOG"; out=$(STUB_FAIL=bad.bin HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy https://e.org/have.bin vae have.bin https://e.org/new.bin loras new.bin https://e.org/bad.bin loras bad.bin 2>&1); code=$?
[[ $code -ne 0 && $out == *"ok   - have.bin is already in models/vae"* && $out == *"ok   - new.bin is in models/loras"* && $out == *"FAIL - download of bad.bin failed"* && -f "$mh/comfy/ComfyUI/models/loras/new.bin" ]] && ok "model script goes on after a failed file and fails at the end" || { fail "model script goes on after a failed file and fails at the end"; echo "$out"; }
[[ $(grep -c "model download" "$LOG") -eq 2 ]] && ok "model script downloads only what is missing" || { fail "model script downloads only what is missing"; cat "$LOG"; }
rm -f "$mh/comfy/ComfyUI/models/loras/"*
free=$(df -Pk "$mh" | awk 'NR==2 {print $4 * 1024}'); half=$((free * 6 / 10))
out=$(STUB_SIZE=$half HOME="$mh" PATH="$WORK/cs:$PATH" bash -c "$mscript" x comfy https://e.org/x.bin loras x.bin https://e.org/y.bin loras y.bin 2>&1); code=$?
[[ $code -ne 0 && $out == *"not enough space"* && ! -e "$mh/comfy/ComfyUI/models/loras/x.bin" ]] && ok "model script refuses when the sum does not fit, even if each file does, and downloads nothing" || { fail "model script refuses when the sum does not fit, even if each file does, and downloads nothing"; echo "$out"; }

# --- model template and --workflow: the models a workflow declares ---
TSV=$(printf 'https://e.org/a.bin\tloras\ta.bin\nhttps://e.org/b.bin\tdiffusion_models/X\tb.bin\n')
STUB_OUT="$TSV" run model template video_x --time 02:00:00
expect_logged "template asks the head node for the models of the template" "models template video_x"
expect_logged "template sends the script as the -c argument" "-c"
expect_logged "template downloads in one cpu job" "hpc-model comfy https://e.org/a.bin loras a.bin https://e.org/b.bin diffusion_models/X b.bin"
expect_logged "template --time applies to the download" "--time=02:00:00"
STUB_OUT="$TSV" STUB_EXIT=1 expect_error "template fails when the cluster refuses" model template nope
STUB_OUT="$TSV" STUB_EXIT=1 run model template nope
expect_not_logged "template downloads nothing when the lookup failed" "srun"
expect_error "template declaring no models fails" model template empty
expect_error "template rejects an unsafe name" model template '../x'
expect_error "template needs a name" model template
expect_error "template takes one name" model template a b
expect_error "template --filter is for the list" model template a --filter x
run model template list --filter minimax
expect_logged "template list asks the head node" "list minimax"
expect_not_logged "template list starts no job" "srun"
printf '{"nodes": []}' > "$WORK/proj/wf.json"
STUB_OUT="$TSV" run model comfy --workflow wf.json
expect_logged "workflow sends the file to the head node" "models stdin -"
expect_logged "workflow downloads what it declares" "hpc-model comfy https://e.org/a.bin loras a.bin"
expect_error "workflow rejects a missing file" model comfy --workflow nope.json
expect_error "workflow rejects URLs next to it" model comfy --workflow wf.json https://e.org/x.bin
expect_error "workflow rejects --to next to it" model comfy --workflow wf.json --to vae
expect_error "workflow is for comfy only" model ollama x --workflow wf.json
# The script: a fake template package, a fake home with one model present.
th="$WORK/th"; mkdir -p "$th/comfy/ComfyUI/models/loras" "$WORK/tp/comfyui_workflow_templates_json/templates"
: > "$WORK/tp/comfyui_workflow_templates_json/__init__.py"
echo x > "$th/comfy/ComfyUI/models/loras/a.bin"
cat > "$WORK/tp/comfyui_workflow_templates_json/templates/video_x.json" <<'JSONEOF'
{"nodes": [{"properties": {"models": [{"name": "a.bin", "url": "https://e.org/a.bin", "directory": "loras"}]}}],
 "definitions": {"subgraphs": [{"nodes": [{"properties": {"models": [
   {"name": "b.bin", "url": "https://e.org/b.bin", "directory": "diffusion_models"},
   {"name": "a.bin", "url": "https://e.org/a.bin", "directory": "loras"}]}}]}]}}
JSONEOF
echo '{"nodes": []}' > "$WORK/tp/comfyui_workflow_templates_json/templates/api_x.json"
wm() { HOME="$th" PYTHONPATH="$WORK/tp" python3 -c "$(cat "$ROOT/remote/workflow_models.py")" "$@" 2>&1; }
out=$(wm models template video_x)
[[ $out == $'https://e.org/a.bin\tloras\ta.bin\nhttps://e.org/b.bin\tdiffusion_models\tb.bin' ]] && ok "workflow script finds the models, subgraphs included, once each" || { fail "workflow script finds the models, subgraphs included, once each"; echo "$out"; }
out=$(echo '{"x": {"name": "m.bin", "url": "https://e.org/m", "directory": "vae"}}' | wm models stdin -)
[[ $out == $'https://e.org/m\tvae\tm.bin' ]] && ok "workflow script reads a workflow from standard input" || { fail "workflow script reads a workflow from standard input"; echo "$out"; }
out=$(wm list ""); 
[[ $out == *"[~]"*"1/2"*"video_x"* && $out != *"api_x"* && $out == *"1 templates with models"* ]] && ok "template list shows the present models and skips the templates without any" || { fail "template list shows the present models and skips the templates without any"; echo "$out"; }
out=$(wm models template nope); code=$?
[[ $out == *"no template named 'nope'"* ]] && ok "workflow script names the missing template" || { fail "workflow script names the missing template"; echo "$out"; }
out=$(HOME="$th" python3 -c "$(cat "$ROOT/remote/workflow_models.py")" models template x 2>&1)
[[ $out == *"run hpc setup comfy"* ]] && ok "workflow script asks for hpc setup when the templates are missing" || { fail "workflow script asks for hpc setup when the templates are missing"; echo "$out"; }

# --- serve: a server as a job, opened on localhost, cancelled on exit ---
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve small --time 02:00:00 jupyter
expect_logged "serve submits with the class preset" "sbatch --parsable --partition=aiq --qos=scavenger"
expect_logged "serve names the job after the service" "--job-name=serve-jupyter"
expect_logged "serve wraps the service command with the port" "--ip=0.0.0.0\\ --port=8888"
expect_logged "serve polls the state and node of the job" "squeue -h -j 77 -o '%T %N'"
expect_logged "serve opens the tunnel on the default port" "-L 8888:ainode02:8888 tester@hpcgate.unical.it"
expect_logged "serve cancels the job when the tunnel ends" "scancel 77"
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve tiny --time 01:00:00 ollama --port 9000
expect_logged "serve --port replaces the default and the placeholder" "OLLAMA_HOST=0.0.0.0:9000"
expect_logged "serve --port moves the tunnel" "-L 9000:ainode02:9000"
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve tiny --time 01:00:00 comfy
expect_logged "serve comfy listens on its port" "--port\\ 8188"
expect_logged "serve comfy runs in the environment made by setup" "envs/comfy/bin"
expect_logged "serve comfy hides the user site" "PYTHONNOUSERSITE=1"
expect_logged "serve comfy points comfy-cli at its environment" "CONDA_PREFIX=\\\$HOME/envs/comfy"
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve tiny --time 01:00:00 ollama
expect_logged "serve ollama uses the binary installed by setup" ".local/bin/ollama"
expect_logged "serve ollama allows only local origins" "OLLAMA_ORIGINS=http://localhost"
expect_not_logged "serve ollama no longer allows ASP-Chef" "alviano.net"
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve cpu --time 01:00:00 --cmd 'python3 -m http.server __PORT__' --port 8000
expect_logged "serve --cmd replaces __PORT__" "python3\\ -m\\ http.server\\ 8000"
expect_logged "serve --cmd names the job" "--job-name=serve-custom"
STUB_SBATCH=77 STUB_OUT="RUNNING ainode02" run serve small --free --push --time 01:00:00 jupyter
expect_logged "serve accepts --free" "hpc-free small"
expect_logged "serve accepts --push" "rsync -az -e"
STUB_SBATCH=77 STUB_OUT="" expect_error "serve fails when the job is gone" serve small --time 01:00:00 jupyter
STUB_SBATCH=77 STUB_OUT="" run serve small --time 01:00:00 jupyter
expect_logged "serve cancels even when the job vanished" "scancel 77"
expect_not_logged "serve does not tunnel without a node" "-L 8888"
STUB_SBATCH=oops expect_error "serve fails when no job ID is returned" serve small --time 01:00:00 jupyter
expect_error "serve needs a service" serve small --time 01:00:00
expect_error "serve rejects an unknown service" serve small --time 01:00:00 nginx
expect_error "serve rejects a service together with --cmd" serve small --time 01:00:00 jupyter --cmd x --port 1
expect_error "serve --cmd needs --port" serve small --time 01:00:00 --cmd x
expect_error "serve rejects a non-numeric port" serve small --time 01:00:00 jupyter --port web
expect_error "serve rejects --requeue" serve small --time 01:00:00 jupyter --requeue
expect_error "serve requires --time" serve small jupyter

# --- wait ---
run wait 123
expect_logged "wait allocates a terminal" "ssh -o ControlPath=none -t tester@hpcgate.unical.it"
expect_logged "wait polls the accounting on the head node" "sacct -X -n -P -j 123 --format=JobID,State,Elapsed,ExitCode"
expect_logged "wait sleeps between polls" "sleep 10"
STUB_EXIT=1 expect_error "wait fails when the job did not complete" wait 123
expect_error "wait rejects non-numeric" wait abc

# --- shell ---
run shell small --time 01:00:00
expect_logged "shell allocates a terminal" "ssh -o ControlPath=none -t tester@hpcgate.unical.it"
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

# --- run: push, submit, wait, pull ---
STUB_OUT="Submitted batch job 77" run run tiny --time 00:05:00 --pull out.csv --pull logs/ job.sbatch
expect_logged "run syncs the project first" "rsync -az -e"
expect_logged "run submits" "sbatch --partition=aiq --qos=scavenger"
expect_logged "run waits for the parsed job ID" "sacct -X -n -P -j 77 --format=JobID,State,Elapsed,ExitCode"
expect_logged "run pulls the first path" "tester@hpcgate.unical.it:projects/proj/./out.csv"
expect_logged "run pulls the second path" "tester@hpcgate.unical.it:projects/proj/./logs/"
expect_not_logged "run keeps --pull away from sbatch" "--pull"
STUB_OUT="Submitted batch job 77" run run cpu --time 00:10:00 job.sbatch -- --array=1-3
expect_logged "run passes options after -- to sbatch" "--array=1-3 job.sbatch"
expect_logged "run waits for the array" "sacct -X -n -P -j 77"
STUB_OUT="no job here" expect_error "run fails when no job ID is returned" run tiny --time 00:05:00 job.sbatch
STUB_OUT="Submitted batch job 77" STUB_EXIT=1 expect_error "run fails when submission fails" run tiny --time 00:05:00 job.sbatch
expect_error "run requires --time" run tiny job.sbatch

# --- --free: require a free slice of the class before submitting ---
run submit small --free --time 00:05:00 job.sbatch
expect_logged "--free asks the Python entry point about the class" "uv run --project $ROOT hpc-free small"
expect_logged "--free still submits when the class is free" "sbatch --partition=aiq"
STUB_EXIT=1 expect_error "--free refuses to submit when uv reports no free slice" submit small --free --time 00:05:00 job.sbatch
STUB_EXIT=1 run submit small --free --time 00:05:00 job.sbatch
expect_not_logged "--free does not reach sbatch when refused" "sbatch"
expect_not_logged "--free does not push when refused" "rsync"
run submit small --time 00:05:00 job.sbatch
expect_not_logged "without --free uv is not run" "hpc-free"
STUB_OUT="Submitted batch job 77" run run small --free --time 00:05:00 job.sbatch
expect_logged "run accepts --free" "hpc-free small"

# --- notifications at the end of wait (and so of run) ---
run wait 123
expect_logged "wait notifies on the desktop" "osascript -e display notification \"job 123 completed\" with title \"hpc\""
STUB_EXIT=1 run wait 123
expect_logged "wait notifies a failure too" "job 123 did not complete"

# --- sweep: one array task per line of the parameter file ---
printf 'a\nb\nc\n' > "$WORK/proj/params.txt"
STUB_OUT="Submitted batch job 5" run sweep tiny --time 00:05:00 --params params.txt job.sbatch
expect_logged "sweep pushes first" "rsync -az -e"
expect_logged "sweep sizes the array on the lines of the file" "--array=1-3"
expect_logged "sweep tells the job where the parameters are" "--export=ALL\\,HPC_SWEEP_FILE=params.txt job.sbatch"
STUB_OUT="Submitted batch job 5" run sweep tiny --time 00:05:00 --params params.txt --parallel 2 job.sbatch -- --job-name=x
expect_logged "sweep limits the tasks running at once" "--array=1-3%2"
expect_logged "sweep keeps the options after --" "--job-name=x"
expect_error "sweep requires --params" sweep tiny --time 00:05:00 job.sbatch
expect_error "sweep rejects a missing parameter file" sweep tiny --time 00:05:00 --params nope.txt job.sbatch
: > "$WORK/proj/empty.txt"
expect_error "sweep rejects an empty parameter file" sweep tiny --time 00:05:00 --params empty.txt job.sbatch

# --- status ---
STUB_OUT="running 1" run status
expect_logged "status counts running jobs" "squeue -u \"\$USER\" -h -t RUNNING"
expect_logged "status counts pending jobs" "-t PENDING"
expect_logged "status shows the last job" "sacct -X -n -P"

# --- short aliases ---
run q
expect_logged "q is queue" "squeue"
run l
expect_logged "l is logs" "tail -n 50"
run w 123
expect_logged "w is wait" "sacct -X -n -P -j 123"
run c 123
expect_logged "c is cancel" "scancel 123"

# --- push honours .hpcignore ---
run push
expect_logged "push excludes what .hpcignore lists" "--filter=:- .hpcignore"

# --- speed: shared connection, login shell only where a job inherits the environment ---
run queue
expect_logged "plain commands share one connection" "ssh -o ControlMaster=auto -o ControlPath=~/.ssh/hpc-%C -o ControlPersist=600"
expect_logged "plain commands load Slurm" "module load slurm && squeue"
expect_not_logged "plain commands skip the login shell" "bash -lc"
run queue -w
expect_not_logged "terminal sessions stay off the shared connection" "ControlMaster"
run submit tiny --time 00:05:00 job.sbatch
expect_logged "submit keeps the login shell" "bash -lc"
run shell tiny --time 00:05:00
expect_logged "shell keeps the login shell" "bash -lc"
run push
expect_logged "push shares the connection" "rsync -az -e ssh -o ControlMaster=auto"
run pull results.csv
expect_logged "pull shares the connection" "rsync -azR -e ssh -o ControlMaster=auto"

echo
[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
