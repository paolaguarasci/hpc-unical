<div align="center">

<img src="https://cdn.simpleicons.org/gnubash/4EAA25" alt="Bash" height="56">
&nbsp;&nbsp;&nbsp;
<img src="https://cdn.simpleicons.org/nvidia/76B900" alt="NVIDIA" height="56">
&nbsp;&nbsp;&nbsp;
<img src="https://cdn.simpleicons.org/gnometerminal/C6FF3D" alt="Terminal" height="56">
&nbsp;&nbsp;&nbsp;
<img src="https://cdn.simpleicons.org/openvpn/EA7E20" alt="OpenVPN" height="56">

# hpc

**One command for the UniCal HPC cluster.**<br>
Submit Slurm jobs with sensible presets, watch the queue, sync files and read logs, straight from your own terminal.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](license)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%203.2%2B-4EAA25?logo=gnubash&logoColor=white)](bin/hpc)
[![Scheduler: Slurm](https://img.shields.io/badge/scheduler-Slurm-0B7BB5)](https://slurm.schedmd.com/)
[![GPU: NVIDIA H200 MIG](https://img.shields.io/badge/GPU-NVIDIA%20H200%20MIG-76B900?logo=nvidia&logoColor=white)](#5-resource-classes)
[![Access: SSH over VPN](https://img.shields.io/badge/access-SSH%20%2B%20OpenVPN-EA7E20?logo=openvpn&logoColor=white)](#1-prerequisites)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?logo=apple&logoColor=white)](#1-prerequisites)
[![Tests: offline suite](https://img.shields.io/badge/tests-offline%20suite-brightgreen)](#11-tests)

</div>

> [!NOTE]
> The offline test suite passes (stubs for `ssh` and `rsync`). The tool has not yet been validated against the live cluster; please report any discrepancy.

Official reference: [Getting started with the UniCal HPC cluster](https://hpcgate.unical.it:8001/public/status/getting-started.html).

## At a glance

|                     |                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| **Presets**         | `tiny`, `small`, `medium`, `large` GPU slices and `cpu`, with the cluster's default CPU and RAM |
| **QoS handling**    | Preemptible `scavenger` by default, protected `gpu_<class>_reserved` with `--booked`            |
| **File sync**       | `push` / `pull` over `rsync`, honouring `.gitignore`, never deleting                            |
| **Monitoring**      | `top` (interactive view), `queue -w`, `logs -f`, `wait`, `info`, `free`, `qos`, `cancel`        |
| **Interactive use** | `shell` on a compute node, `tunnel` to a server run by a job, `doctor` to check the setup       |
| **Safe by default** | A wall-clock limit is mandatory; the cluster login stays in a git-ignored `.env`                |

## Contents

- [hpc](#hpc)
  - [At a glance](#at-a-glance)
  - [Contents](#contents)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Installation](#2-installation)
  - [3. Quick start](#3-quick-start)
  - [4. Command reference](#4-command-reference)
    - [`submit`](#submit)
    - [`run`](#run)
    - [`sweep`](#sweep)
    - [`status`](#status)
    - [`queue`](#queue)
    - [`top`](#top)
    - [`qos`](#qos)
    - [`push` and `pull`](#push-and-pull)
    - [`logs`](#logs)
    - [`cancel`](#cancel)
    - [`shell`](#shell)
    - [`tunnel`](#tunnel)
    - [`serve`](#serve)
    - [`setup`](#setup)
    - [`model`](#model)
    - [`download`](#download)
    - [`wait`](#wait)
    - [`doctor`](#doctor)
    - [`info`](#info)
    - [`free`](#free)
    - [Zsh completion](#zsh-completion)
  - [5. Resource classes](#5-resource-classes)
  - [6. QoS, bookings and preemption](#6-qos-bookings-and-preemption)
  - [7. Writing your own job](#7-writing-your-own-job)
  - [8. Interactive services: Jupyter, ComfyUI and Ollama](#8-interactive-services-jupyter-comfyui-and-ollama)
    - [One-time setup](#one-time-setup)
    - [Starting and stopping](#starting-and-stopping)
    - [Jupyter](#jupyter)
    - [Ollama](#ollama)
    - [ComfyUI](#comfyui)
      - [From the "Missing models" panel to the download](#from-the-missing-models-panel-to-the-download)
    - [Security](#security)
    - [Problems](#problems)
  - [9. How it works](#9-how-it-works)
  - [10. Troubleshooting](#10-troubleshooting)
  - [11. Tests](#11-tests)
  - [Public page](#public-page)
  - [Before you leave](#before-you-leave)
  - [License](#license)

---

## 1. Prerequisites

> [!IMPORTANT]
> **The university VPN is required.** The cluster head node is reachable only through the university OpenVPN, which must be **active every time you run `hpc`**. The OpenVPN configuration is not part of this repository: **request it through UniTicket**.

- A cluster account and the OpenVPN configuration described above.
- `ssh` access to `hpcgate.unical.it` with your cluster login, with your public key uploaded ([installation, step 1](#2-installation)); otherwise every command asks for the password.
- `bash`, `ssh` and `rsync` on your machine (the stock macOS versions are sufficient).

## 2. Installation

```bash
# 1. Upload your SSH public key to the cluster (once; connect the VPN first).
#    Create a key if you have none, then copy it; the password is asked only this time.
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519
ssh-copy-id YOUR_LOGIN@hpcgate.unical.it
ssh YOUR_LOGIN@hpcgate.unical.it hostname     # must print the host name without asking for the password

# 2. Make the command available on your PATH (adapt the target directory if needed)
ln -s "$PWD/bin/hpc" ~/.local/bin/hpc

# 3. Tell the tool who you are: copy the example and set your cluster login
cp .env.example .env        # then edit it: HPC_USER=your_cluster_login
```

If `ssh-copy-id` fails or the password is still requested afterwards, the cluster may not accept keys for your account: report the exact message to cluster support.

`HPC_USER` is mandatory: the command fails immediately if it is set neither in `.env` nor in the environment. A variable already exported in your shell takes precedence over `.env`. The file is located through the symlink, so `hpc` works from any directory, and it is git-ignored (and therefore not pushed to the cluster). The cluster host (`hpcgate.unical.it`) is fixed.

## 3. Quick start

Connect the VPN, then run a five-second smoke test on the smallest GPU slice **from the repository root**.

```bash
hpc qos                                                 # 1. check which QoS your account may use
hpc push                                                # 2. copy this directory to ~/projects/hpc on the cluster
hpc submit tiny --time 00:05:00 templates/demo.sbatch   # 3. submit; Slurm prints "Submitted batch job N"
hpc queue                                               # 4. PENDING -> RUNNING -> COMPLETED
hpc logs                                                # 5. read the output of the latest job
```

The demo prints the job ID, the home directory, the working directory, the compute node (`ainode01` or `ainode02`) and `CUDA_VISIBLE_DEVICES`. For a run without a GPU, replace `tiny` with `cpu`.

## 4. Command reference

| Command                                                       | Purpose                                                                                     |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `hpc submit CLASS --time T [options] SCRIPT`                  | Submit a batch script with the preset of `CLASS`                                            |
| `hpc run CLASS --time T [options] SCRIPT`                     | Push, submit, wait and pull the results in one command                                      |
| `hpc sweep CLASS --time T --params FILE ...`                  | Job array with one task per line of a parameter file                                        |
| `hpc status`                                                  | Running and pending jobs and the last job, in one line                                      |
| `hpc queue [-w [SECONDS]]`                                    | Your pending and running jobs, plus the last 24 hours of history                            |
| `hpc top`                                                     | Interactive view of the cluster and of your jobs (requires `uv`)                            |
| `hpc qos`                                                     | QoS associations granted to your account                                                    |
| `hpc push`                                                    | Sync the current directory to the cluster                                                   |
| `hpc pull PATH...`                                            | Fetch files from the cluster project directory                                              |
| `hpc logs [ID] [-f]`                                          | Show or follow a job's output                                                               |
| `hpc cancel ID`                                               | Cancel a job                                                                                |
| `hpc shell CLASS --time T [options]`                          | Interactive shell on a compute node with the preset of `CLASS`                              |
| `hpc tunnel ID PORT`                                          | Forward a local port to a server run by job `ID`                                            |
| `hpc serve CLASS --time T SERVICE`                            | Run Jupyter, ComfyUI, Ollama or a custom server and open it on localhost                    |
| `hpc setup [ollama] [comfy] [vllm] [tensorboard]`             | Check ollama, ComfyUI, vLLM and TensorBoard on a cpu node and install what is missing                        |
| `hpc model comfy [--to KIND] URL...`, `hpc model ollama NAME` | Download models on the cluster, in a cpu job                                                |
| `hpc model list [comfy\|ollama]`                              | List the downloadable ComfyUI models and the Ollama models installed, marking those present |
| `hpc model template NAME`, `hpc model comfy --workflow FILE`  | Download the models that a ComfyUI template or workflow file declares                       |
| `hpc wait ID`                                                 | Block until job `ID` ends; succeed only if it completed                                     |
| `hpc doctor`                                                  | Check tools, VPN and SSH access, Slurm and the project directory                            |
| `hpc info ID`                                                 | CPU and memory efficiency of a finished job                                                 |
| `hpc free`                                                    | Classes with a free GPU slice right now (requires `uv`)                                     |
| `hpc help`                                                    | Print usage                                                                                 |

`q`, `l`, `w` and `c` are short for `queue`, `logs`, `wait` and `cancel`. `hpc wait` (and so `hpc run`) also posts a macOS notification when the job ends, if `osascript` is available.

Wherever a command takes a job ID, a task of a job array is written `ID_TASK`, for instance `10211_2`.

### `submit`

```bash
hpc submit CLASS --time HH:MM:SS [--booked] [--requeue] [--push] [--cpus N] [--mem SIZE] SCRIPT [-- SBATCH_OPTION...]
```

| Option                   | Meaning                                                                                                                |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `CLASS`                  | `tiny`, `small`, `medium`, `large` or `cpu` (see [section 5](#5-resource-classes))                                     |
| `--time T`               | **Required.** Wall-clock limit, e.g. `00:30:00` or `1-12:00:00`. The partition has no default limit, so always set one |
| `--booked`               | Use the protected QoS `gpu_<class>_reserved` (requires an active booking). Not available for `cpu`                     |
| `--requeue`              | Allow Slurm to put the job back in the queue after preemption. Use only if restarting the script is safe               |
| `--push`                 | Run `hpc push` first, so that the job cannot start on a stale copy of the project                                      |
| `--free`                 | Fail at once, before pushing, unless a GPU slice of `CLASS` is free now (requires `uv`; not for `cpu`)                 |
| `--cpus N`, `--mem SIZE` | Override the class defaults (e.g. `--mem 48G`)                                                                         |
| `SCRIPT`                 | Path **relative to the project directory**, e.g. `job.sbatch` or `templates/demo.sbatch`                               |
| `-- SBATCH_OPTION...`    | Everything after `--` is passed to `sbatch` unchanged, e.g. `--array`, `--job-name` or `--dependency`                  |

Examples:

```bash
hpc submit small --time 02:00:00 train.sbatch                 # preemptible, no booking
hpc submit medium --time 12:00:00 --requeue train.sbatch      # restartable after preemption
hpc submit large --booked --time 24:00:00 train.sbatch        # protected, needs a Large booking
hpc submit cpu --time 00:10:00 --cpus 4 preprocess.sbatch     # CPU only
hpc submit cpu --time 01:00:00 run.sbatch -- --array=1-50%10  # job array: 50 tasks, 10 at a time
hpc submit small --time 02:00:00 --push train.sbatch          # sync the project, then submit
```

The command always adds `--partition=aiq --nodes=1 --ntasks=1` and the profile as `--gres=gpu:<profile>:1`. Resources and QoS given on the command line override any `#SBATCH` line in the script, so keep them out of your scripts. The options after `--` are placed after the presets and are not validated: a repeated option (for instance a second `--mem`) replaces the preset. In a job array, each task gets the resources of the class, and `%x-%j.out` gives each task a log of its own.

### `run`

```bash
hpc run CLASS --time HH:MM:SS [--booked] [--requeue] [--cpus N] [--mem SIZE] [--pull PATH]... SCRIPT [-- SBATCH_OPTION...]
```

Runs `hpc submit --push`, then `hpc wait` on the job, then `hpc pull` for each `--pull PATH` (repeatable). It accepts the options of `submit`, except `--push`, which is always on. The results are fetched only if the job completed; otherwise the command fails and names `hpc logs ID`. The exit status is therefore that of `hpc wait`. For a job array, the command waits for every task.

```bash
hpc run small --time 02:00:00 --pull results.csv --pull plots/ train.sbatch
```

### `sweep`

```bash
hpc sweep CLASS --time HH:MM:SS --params FILE [--parallel N] [options] SCRIPT [-- SBATCH_OPTION...]
```

Pushes the project and submits `SCRIPT` as a job array with one task per line of `FILE` (path relative to the project directory), accepting the options of `submit`. `--parallel N` limits the tasks running at once (`--array=1-<lines>%N`); keep it low on the shared slices. Each task finds the path of the file in `HPC_SWEEP_FILE` and reads its own line:

```bash
params=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$HPC_SWEEP_FILE")
python train.py $params
```

### `status`

```bash
hpc status      # running 1 | pending 0 | last: 10370|demo|COMPLETED|00:00:09
```

One SSH call: the jobs of your account that are running or pending, and the last job of the past seven days. For free GPU slices use `hpc free`.

### `queue`

Prints `squeue` for your user (job ID, name, state, elapsed time, **effective QoS**, node or pending reason) followed by `sacct` for the last 24 hours. Jupyter kernels are Slurm jobs and appear here too.

```bash
hpc queue         # print once
hpc queue -w      # live view, refreshed every 10 seconds (Ctrl-C to stop)
hpc queue -w 30   # live view, refreshed every 30 seconds
```

The live view keeps a single SSH session open and runs `watch` on the head node.

### `top`

Opens an interactive, full-screen view that refreshes every 5 seconds:

- **Nodes**: bar charts of the allocated CPU cores, memory and GPU slices (per MIG profile) of each node of the `aiq` partition, the trend of CPU and GPU allocation since the view was opened, and, on the lower border, the classes that have a free GPU slice right now.
- **My jobs**: your pending and running jobs, coloured by state; a pending job shows the estimated start time when Slurm provides one.
- **Details**: for the highlighted job, its state, node and account; when it was submitted and started, how long it waited in the queue and when it ends; bars of the elapsed time against the limit and, while it runs, of the peak memory and GPU memory against the request, with the trend of their current values; cores and CPU time. A job that has run for five minutes using less than half of the requested memory is flagged. For a finished job the panel reports the CPU and memory efficiency computed by `seff`.
- **Log**: the last 200 lines of the `*-<job ID>.out` file of the highlighted job, followed live.
- **Last 24 h**: the jobs that ended in the last day, with their state and exit code.

| Key           | Action                                                                   |
| ------------- | ------------------------------------------------------------------------ |
| `Up` / `Down` | Highlight a job; the log panel follows it                                |
| `Tab`         | Move between the job list, the log and the history                       |
| `c`           | Cancel the highlighted pending or running job, after a prompt            |
| `l`           | Open the whole log in `less` on the cluster (`q` to return)              |
| `t`           | Open an SSH tunnel to a port of the highlighted running job, or close it |
| `a`           | Switch the job list between your jobs and the jobs of every user         |
| `r`           | Refresh now                                                              |
| `q`           | Quit                                                                     |

**All jobs.** `a` lists the pending and running jobs of every user, with a column for the owner, to show what occupies the cluster while a job of yours is pending. The jobs of other users are only listed: their logs and usage are never read, and they cannot be cancelled or tunnelled. The counters in the title bar always refer to your jobs.

**Alerts.** While the view is open, a notification is raised when one of your jobs starts, ends (with its final state and exit code) or has used 90% of its time limit. On macOS it is also sent to the notification centre.

**Tunnels.** `t` asks for a port and forwards `localhost:<port>` to the same port on the node of the job, through the head node; the address appears in the job list, followed by `✓` when a server answers on that port or by `✗ no server` when nothing listens there (check the port in the log). Tunnels are closed when the job ends or the view is quit.

The view is a [Textual](https://textual.textualize.io/) application (`hpc_top/`) that runs on your machine; it requires [`uv`](https://docs.astral.sh/uv/), which installs the Python dependencies on first use. Each refresh is one SSH command, and all of them share a single multiplexed connection; refreshes never overlap, and a command that gets no answer within 30 seconds is stopped and reported. The pager and the tunnels use connections of their own.

### `qos`

Shows the QoS names your account is associated with. After a booking starts, allow up to five minutes for the new QoS to appear.

### `push` and `pull`

Files matched by a `.hpcignore` in the project directory (same syntax as `.gitignore`) are not sent, in addition to those ignored by Git. `push` never deletes anything on the cluster, so that job outputs are safe.

```bash
hpc push                         # ./  ->  ~/projects/<current directory name>/
hpc pull results.csv             # ~/projects/<name>/results.csv  ->  ./results.csv
hpc pull out/model.pt logs/a.txt # relative paths are preserved: ./out/model.pt, ./logs/a.txt
```

- `push` honours your `.gitignore`, excludes `.git`, and **never deletes** files on the cluster.
- `pull` is explicit on purpose: it fetches only the paths you name, so it cannot overwrite your local code.
- Both can overwrite files that changed on the other side; keep an independent copy of irreplaceable data (the cluster guide establishes no backup guarantee for `/home`).

### `logs`

```bash
hpc logs          # latest *.out in the project directory
hpc logs 4821     # the output of job 4821
hpc logs -f       # follow the latest output (Ctrl-C to stop)
hpc logs 4821 -f
hpc logs 4821_3   # task 3 of the job array 4821
```

The lookup relies on the default naming `slurm-<id>.out` or the `%x-<id>.out` pattern used by the templates. Both name the file after the job's own ID, which for a task of a job array differs from `ID_TASK`; `hpc logs` asks Slurm for it.

### `cancel`

```bash
hpc cancel 4821
```

### `shell`

```bash
hpc shell CLASS --time HH:MM:SS [--booked] [--push] [--cpus N] [--mem SIZE] [-- SRUN_OPTION...]
```

Opens an interactive shell on a compute node (`srun --pty bash -l`), with the same presets, QoS rules and options as `submit`; it starts in the project directory, so run `hpc push` first or add `--push`. Use it to build or test an environment instead of working on the head node. The session is a Slurm job: it is preemptible unless booked, it ends at the time limit, and it holds its resources until you leave it with `exit`.

```bash
hpc shell cpu --time 00:30:00          # one core, to try a Conda environment
hpc shell tiny --time 01:00:00         # with the smallest GPU slice
```

### `tunnel`

```bash
hpc tunnel 4821 8000     # http://localhost:8000 -> port 8000 on the node that runs job 4821
```

Forwards `localhost:PORT` to the same port of the compute node of a running job, through the head node, until Ctrl-C. The command fails when the job has no node (pending or finished) or when the local port is already in use. It does not check that a server listens on the remote port: a connection that is reset at once means that nothing does (the `t` key of `hpc top` performs that check).

### `serve`

```bash
hpc serve CLASS --time HH:MM:SS (jupyter|comfy|ollama|vllm MODEL|tensorboard [LOGDIR] | --cmd COMMAND --port PORT) [--port PORT] [--args OPTIONS] [--booked] [--push] [--free] [--cpus N] [--mem SIZE] [-- SBATCH_OPTION...]
```

Submits the server as a job (`sbatch --wrap`, with the presets and QoS rules of `submit`), waits until it runs, then until the server accepts connections on its port (a TCP probe from the head node, every 5 seconds: vLLM, for instance, opens its port only after minutes of loading), then forwards `localhost:PORT` to its node, as `tunnel` does. If the job leaves `RUNNING` while it waits, `serve` fails and points to `hpc logs ID`; there is no separate timeout, the limit is the job's `--time`. **Ctrl-C closes the tunnel and cancels the job**; so do a `kill` of the `hpc` process (TERM), the closing of the terminal and a dropped connection. Only `kill -9` and a crash of your machine leave the job running until its `--time` expires: `hpc queue` shows it (`serve-<service>`) and `hpc cancel ID` ends it. The job starts in the project directory (use `--push` to sync it first) and is named `serve-<service>`, so several services can run together on different ports.

| Service   | Default local port | Command run on the node                                                                  |
| --------- | ------------ | ---------------------------------------------------------------------------------------- |
| `jupyter` | 8888         | `jupyter lab --no-browser --ip=0.0.0.0` (the token is in `hpc logs ID`)                  |
| `comfy`   | 8188         | `~/envs/comfy/bin/comfy-cli launch` with `~/comfy/ComfyUI/` as the default workspace     |
| `ollama`  | 11434        | `~/.local/bin/ollama serve`, with `OLLAMA_ORIGINS=http://localhost:*,http://127.0.0.1:*` |
| `vllm`    | 8000         | `~/envs/vllm/bin/vllm serve MODEL --host 0.0.0.0` (OpenAI-compatible API; `MODEL` is required)   |
| `tensorboard` | 6006     | `~/envs/tensorboard/bin/tensorboard --logdir LOGDIR --host 0.0.0.0` (`LOGDIR` defaults to the project directory) |

`--args OPTIONS` (only for `vllm` and `tensorboard`) appends `OPTIONS`, as typed, to the command of the service, for instance `--args "--reasoning-parser qwen3 --max-model-len 8192"`; the options are not validated, so a wrong one makes the server fail at start (see `hpc logs ID`). Everything after `--` is, as in `submit`, for Slurm, not for the server.

The nodes are shared with other users, so a fixed port can already be taken there: **the job picks a free port on the node** (random, between 20000 and 39999, one nobody listens on), announces it in its log as `HPC_PORT=N`, and runs the service on it. `serve` reads that line, waits for the port, and forwards `localhost:PORT` to it, so `--port` and the "default local port" above are the ports on your machine only. With `--cmd`, `__PORT__` in the command is replaced by the port picked by the job (`--port` is still required, as the local port). The tunnel reaches the node through the head node, not through its loopback, so **the server must listen on all interfaces** (`0.0.0.0`): other users of the cluster network can reach that port, hence keep a token or another protection enabled. `jupyter` must already be in your environment; `comfy` and `ollama` are installed by [`hpc setup`](#setup).

```bash
hpc serve small --time 04:00:00 jupyter                       # http://localhost:8888
hpc serve medium --time 02:00:00 ollama --port 11500
hpc serve medium --time 02:00:00 vllm Qwen/Qwen3-8B           # http://localhost:8000/v1
hpc serve medium --time 02:00:00 vllm Qwen/Qwen3-8B --args "--reasoning-parser qwen3"
hpc serve cpu --time 02:00:00 tensorboard runs                # http://localhost:6006
hpc serve cpu --time 00:30:00 --cmd 'python3 -m http.server __PORT__' --port 8000
```

### `setup`

```bash
hpc setup [ollama] [comfy] [vllm] [tensorboard] [--time HH:MM:SS]
```

Checks ollama, ComfyUI, vLLM and TensorBoard and installs what is missing, so that `hpc serve ... ollama|comfy|vllm|tensorboard` works. Without arguments it handles ollama and ComfyUI only: vLLM brings its own PyTorch (several gigabytes), so it is asked for by name. The work runs in a `cpu` job (`srun`, default `--time 01:00:00`), not on the head node, and prints `ok` or `FAIL` for each component; the exit status is non-zero when one fails. It is safe to run again: what is already installed is left alone.

| Component | Installed in                                                                                                                |
| --------- | --------------------------------------------------------------------------------------------------------------------------- |
| `ollama`  | `~/.local/bin/ollama` and `~/.local/lib/ollama`, from the official `.tar.zst` archive (needs `zstd` on the node)            |
| `comfy`   | conda environment `~/envs/comfy` (Python 3.12, `comfy-cli`) and ComfyUI in `~/comfy/ComfyUI` (`comfy-cli install --nvidia`) |
| `vllm`    | conda environment `~/envs/vllm` (Python 3.12, `pip install vllm`)                                                           |
| `tensorboard` | conda environment `~/envs/tensorboard` (Python 3.12, `pip install tensorboard`)                                         |

The ComfyUI install runs with `CONDA_PREFIX` pointing at `~/envs/comfy`, that environment first on the `PATH` and the user site hidden (`PYTHONNOUSERSITE=1`), and `serve comfy` does the same: `comfy-cli` takes its Python from `CONDA_PREFIX`, which a login shell sets to the conda base, and the base cannot be written, so without this pip fails or falls back to `~/.local` and pollutes the base environment. If `~/comfy/ComfyUI` exists but the environment has no PyTorch (a past install that went wrong), `setup` fails instead of reinstalling over it: move `~/comfy` aside and run it again.

Only the software is installed: no model is downloaded and no custom node is added. The node must reach `ollama.com`, `pypi.org`, `github.com` and the conda channels; if it cannot, the component fails with a message saying so. The files live in the shared `/home`, which has no quota or backup guarantee, and ComfyUI with PyTorch takes several gigabytes.

### `model`

```bash
hpc model comfy [--to KIND] URL... [--to KIND URL...] [--filename NAME] [--time HH:MM:SS]
hpc model ollama NAME [--time HH:MM:SS]
hpc model list [comfy|ollama] [--type TYPE] [--filter TEXT] [--urls]
hpc model template NAME [--time HH:MM:SS]
hpc model template list [--filter TEXT]
hpc model comfy --workflow FILE.json [--time HH:MM:SS]
```

Downloads a model **on the cluster**, in a `cpu` job (default `--time 01:00:00`), so that the file never goes through your computer. The ComfyUI button "Download" in the web interface downloads through your browser, onto your machine: use this command (or the Model Manager of ComfyUI-Manager) instead.

- `comfy`: each file at a `URL` goes to `~/comfy/ComfyUI/models/KIND`, with `KIND` the models folder shown by ComfyUI: `checkpoints`, `loras`, `vae`, `text_encoders`, `diffusion_models`, ... (sub-folders are allowed, such as `diffusion_models/FLUX1`; no segment may start with a dot). Several URLs go in one command and one job: **a `--to` applies to the URLs after it**, and a URL written before any `--to` takes the first one. The file name is the last part of the URL, without its query string; `--filename` overrides it and is accepted for a single URL only. Every URL must be `https://`. The download is done by `comfy-cli model download`.
- `ollama`: pulls the model `NAME` (for instance `llama3.2:1b`) into `~/.ollama`, with a private Ollama server started on the node for the time of the pull. Without a tag, `:latest` is meant.
- Safe to repeat: a model that is already there is skipped and **a file is never overwritten** (a file of the same name and another size is reported as `FAIL`, to be removed by you). The free space of the home is compared with the **sum** of the announced sizes before anything is downloaded: if the total does not fit, nothing is downloaded. After that every file is tried, a failed one does not stop the others, and the command exits with an error if any failed. A file whose server does not announce the size is left out of the sum, and the command says so.
- `template` and `--workflow`: you do not need to copy any URL. A ComfyUI workflow declares, for each model, its folder, file name and download URL (this is what the "Missing models" panel reads). `hpc model template NAME` downloads all the models of a template installed with ComfyUI on the cluster, for instance `hpc model template video_minimax_h3_i2v`; `hpc model template list [--filter minimax]` shows the templates that declare models and how many of them are present (`[x]` all, `[~]` some, `[ ]` none). `hpc model comfy --workflow FILE.json` does the same for a workflow file of yours (the file is sent to the head node, and no URL, `--to` or `--filename` may be given with it). The download follows the rules above (space on the sum, no overwriting, a failed file does not stop the others). Templates of the cloud APIs (`api_*`) declare no models and are not listed.
- `list`: shows the ComfyUI models of the catalogue of ComfyUI-Manager (about 500: type, target folder, size, name and file) and the Ollama models installed, with `[x]` on those already present and `[ ]` on the others. `--type lora` keeps one catalogue type, `--filter flux` the models whose name, file, base or folder contains the text (case-insensitive), `--urls` adds the download URL to give to `hpc model comfy`. The folder of a row is the value for `--to` (it may have sub-folders, such as `diffusion_models/FLUX1`). It reads files on the head node and starts no job. A ComfyUI model is "present" when its file is in that exact folder under `~/comfy/ComfyUI/models`. The catalogue is not complete (recent models may be missing: use the URL of the model directly), and for Ollama only the installed models are listed, because the catalogue of [ollama.com/library](https://ollama.com/library) has no official API.
- Needs `hpc setup comfy` or `hpc setup ollama` first. Models from sites that require a login (private Hugging Face or CivitAI files) are not supported.

```bash
hpc model list comfy --type lora --filter flux --urls          # what exists, what is already there
hpc model comfy "https://huggingface.co/ORG/REPO/resolve/main/model.safetensors" --to diffusion_models
hpc model comfy --to loras URL1 --to vae URL2 URL3 --to text_encoders URL4 --to diffusion_models URL5   # one job, five files
hpc model template video_minimax_h3_i2v                            # the models of a ComfyUI template, no URL needed
hpc model ollama llama3.2:1b
```

### `download`

```bash
hpc download comfy [--to DIR] [--latest N] [PATH...]
```

Copies the results of ComfyUI from `~/comfy/ComfyUI/output` on the cluster to `DIR` on this machine (default `./comfy-output`, created if missing; run it from where you want the files). It uses `rsync`: a file already there is skipped, **nothing is ever deleted**, either here or on the cluster, and an interrupted copy resumes. Videos and images are already compressed, so they are sent without further compression.

- no arguments: everything that is new;
- `PATH...`: only those files or folders, given relative to the output folder (for instance `video/MiniMax_H3_00001_.mp4`), with their folders kept; a path may not contain spaces or `..`;
- `--latest N`: the `N` most recent files (the cluster is asked for their names first); not to be combined with `PATH`.

```bash
hpc download comfy --latest 1                 # the last video you generated
hpc download comfy                            # everything new
hpc download comfy video/MiniMax_H3_00001_.mp4 --to ~/Videos/comfy
```

It reads files only: it does not need the ComfyUI job to be running, so the results can be fetched after `serve` has been stopped.

### `wait`

```bash
hpc wait 4821 && hpc pull results.csv     # fetch the results only if the job completed
```

Blocks until the job ends, then prints its final state, elapsed time and exit code. The exit status is 0 only when the state is `COMPLETED` (for a job array, when every task completed), so the command can gate what follows. A single SSH session is kept open and the accounting is polled every 10 seconds on the head node; if the connection drops, the command fails and can simply be run again.

### `doctor`

```bash
hpc doctor
```

Checks, in order: `ssh`, `rsync` and `uv` on your machine; that the head node answers with your SSH key (which also proves that the VPN is up); that Slurm loads on the head node; that the project directory of the current directory exists on the cluster. Each line is `ok` or `FAIL` with the action to take, and the exit status is non-zero when a check fails. The cluster checks are skipped when the head node does not answer.

### `info`

```bash
hpc info 4821
```

Prints the report of `seff` for a finished job: state, cores, CPU time used and CPU efficiency, wall-clock time, memory used and memory efficiency. Read it after a run to size `--cpus` and `--mem` of the next one.

### `free`

```bash
hpc free
# ainode01  free now: tiny 4 · small 4 · medium 4 · large 4
# ainode02  free now: tiny 2 · small 4 · medium 2 · large 3
```

Lists, for each node, the classes that have a free GPU slice right now and how many, to choose a class before submitting. It considers GPU slices only, not free cores, memory or QoS limits. The same check is available as `--free` on `submit`, `run` and `shell`, which refuse to start when the class has no free slice. It reuses the code of `hpc top`, so it requires [`uv`](https://docs.astral.sh/uv/).

### Zsh completion

```bash
mkdir -p ~/.zfunc && ln -s "$PWD/completions/_hpc" ~/.zfunc/_hpc
# in ~/.zshrc, before compinit:  fpath=(~/.zfunc $fpath)
```

Completes subcommands, classes and the IDs of your jobs (the latter asks the cluster, so it takes about a second).

## 5. Resource classes

The compute partition is `aiq` (nodes `ainode01`, `ainode02`). The NVIDIA H200 GPUs are exposed as MIG slices. Presets match the cluster's per-instance defaults.

| Class    | Slurm profile | GPU memory | CPU cores | RAM     | Instances      |
| -------- | ------------- | ---------- | --------- | ------- | -------------- |
| `tiny`   | `1g.35gb`     | ~35 GB     | 2         | 32 GiB  | 8              |
| `small`  | `2g.35gb`     | ~35 GB     | 3         | 64 GiB  | 8              |
| `medium` | `4g.71gb`     | ~71 GB     | 6         | 128 GiB | 8              |
| `large`  | `7g.141gb`    | ~141 GB    | 11        | 240 GiB | 8 (7 bookable) |
| `cpu`    | none          | none       | 1         | 16 GiB  | n/a            |

Choose by **both** GPU memory and compute: `tiny` and `small` have similar memory but different compute capacity. `--mem` requests system RAM, never GPU memory. Preemptible jobs are limited to 256 GiB RAM each.

## 6. QoS, bookings and preemption

| Mode            | How                             | QoS                    | Behaviour                                                                       |
| --------------- | ------------------------------- | ---------------------- | ------------------------------------------------------------------------------- |
| Without booking | `hpc submit CLASS ...`          | `scavenger`            | Preemptible; SIGTERM with a 270 s grace period; restarted only with `--requeue` |
| With booking    | `hpc submit CLASS --booked ...` | `gpu_<class>_reserved` | Not preempted by current policy; one job at a time per booked QoS               |

Essentials:

- **Bookings** are made in the portal (System → Booking). A booking grants QoS access during its period; it does not start a job. Wait up to five minutes after the start, then check with `hpc qos`.
- A booked QoS allows **one submitted job in total**, and a running notebook kernel counts as that job.
- Do not use `--reservation`: bookings grant a QoS, not a Slurm reservation.
- Finish and release your job **before the booking ends**; expiry does not terminate a running job but triggers notifications.
- Limits per user on `scavenger`: six instances of each profile and 24 in total.

> [!WARNING]
> **Preemption** can stop a job at any time. Slurm does not save state: your application must write checkpoints and reload them when restarted. See the SIGTERM handling in `templates/job.sbatch`.

## 7. Writing your own job

Copy the template and adapt it:

```bash
cp templates/job.sbatch train.sbatch
```

`templates/job.sbatch` provides:

- output to `<job-name>-<job-id>.out`;
- `cd "$SLURM_SUBMIT_DIR"`, so relative paths resolve inside the project directory;
- a commented line to activate your Conda environment (a Jupyter kernel selection does **not** configure a batch job, so activate the environment inside the script);
- a SIGTERM trap that forwards the signal to your application, which must checkpoint on its own;
- `srun python train.py`, the line to replace with your command.

Rules for `#SBATCH` lines: they are parsed by Slurm, not Bash, so shell variables such as `$HOME` are not expanded, and they must precede any executable line.

Typical cycle:

```bash
hpc push
hpc submit small --time 04:00:00 --requeue train.sbatch   # prints "Submitted batch job N"
hpc queue
hpc logs -f
hpc wait N && hpc pull checkpoints/latest.pt results.csv
```

## 8. Interactive services: Jupyter, ComfyUI and Ollama

[`hpc serve`](#serve) runs a server as a Slurm job on a compute node and opens it on `localhost`. The services below have a preset; anything else goes through `--cmd`.

> [!NOTE]
> The presets are based on three launcher scripts by Professor Alviano (`hpc-jupy.sh`, `hpc-comfy.sh` and `hpc-ollama.sh`): the service commands and their options come from them. `hpc serve` differs in how it runs the job and the tunnel (a batch job with the presets and QoS rules of `submit`, and a direct SSH forward instead of a reverse tunnel over a unix socket).

| Service   | Needs                               | Start                                     | Address                  | Authentication         |
| --------- | ----------------------------------- | ----------------------------------------- | ------------------------ | ---------------------- |
| `jupyter` | `jupyter` in your login environment | `hpc serve small --time 04:00:00 jupyter` | `http://localhost:8888`  | token (in the job log) |
| `comfy`   | `hpc setup comfy`                   | `hpc serve small --time 04:00:00 comfy`   | `http://localhost:8188`  | none                   |
| `ollama`  | `hpc setup ollama`                  | `hpc serve tiny --time 04:00:00 ollama`   | `http://localhost:11434` | none                   |
| `vllm`    | `hpc setup vllm`                    | `hpc serve medium --time 04:00:00 vllm MODEL` | `http://localhost:8000/v1` | none               |
| `tensorboard` | `hpc setup tensorboard`         | `hpc serve cpu --time 04:00:00 tensorboard [LOGDIR]` | `http://localhost:6006` | none          |

### One-time setup

1. Connect the VPN and check the access: `hpc doctor`.
2. Install what is missing, once: `hpc setup` (both) or `hpc setup ollama` / `hpc setup comfy`. It runs in a `cpu` job, prints `ok` or `FAIL` for each component and can be run again safely (see [`setup`](#setup)). ComfyUI with PyTorch takes several gigabytes of the shared `/home`.
3. Jupyter needs nothing if `jupyter` is already in your login environment: check with `hpc shell cpu --time 00:05:00`, then `command -v jupyter`, then `exit`.

### Starting and stopping

- `hpc serve CLASS --time T SERVICE` prints the job ID and the address, then keeps the tunnel open. **Ctrl-C closes the tunnel and cancels the job.**
- Choose the class by the GPU memory the model needs (it is in the profile name: `1g.35gb`, `2g.35gb`, `4g.71gb`, `7g.141gb`) and always set the shortest realistic `--time`.
- By default the job is preemptible: when Slurm preempts it the server stops and the tunnel drops. Use `--booked` for a protected run, if you hold a booking ([section 6](#6-qos-bookings-and-preemption)).
- The server needs a few seconds after the job starts (up to a minute for ComfyUI): a connection reset at first is normal. Follow the start-up with `hpc logs ID -f`.
- Another port: `--port N` (for instance when another user already holds the default one on the same node).

### Jupyter

- The token is printed in the job log: run `hpc logs ID` and open the `http://127.0.0.1:8888/lab?token=...` address with `localhost:8888`.
- The job starts in the project directory on the cluster; add `--push` to sync the current directory first.
- To offer another conda environment as a kernel, run once inside it (for instance in `hpc shell cpu`): `python -m ipykernel install --user --name NAME`.

### Ollama

- **`OLLAMA_ORIGINS`** lists the web origins whose pages may call the Ollama API from a browser. Without it Ollama accepts only `localhost`, and the browser (CORS) blocks a web application served from another address that tries to use `http://localhost:11434` through the tunnel. The preset sets it to `http://localhost:*,http://127.0.0.1:*`: an application on your machine, on any port, may use the server; no other site may. It is not needed by `curl` or by the `ollama` client. To allow a web application served from another address, start the server with `--cmd` and your own value, for instance `hpc serve tiny --time 02:00:00 --port 11434 --cmd 'OLLAMA_ORIGINS=https://my.app OLLAMA_HOST=0.0.0.0:__PORT__ exec ~/.local/bin/ollama serve'`; a page of that site, opened in your browser while the tunnel is up, can then use your Ollama (`OLLAMA_ORIGINS=*` accepts every origin and is not advisable).
- Models are stored in `~/.ollama` of the shared `/home` and survive from one `serve` to the next; the server does not.
- Download a model on the cluster with [`hpc model ollama NAME`](#model), then use it through the tunnel, for instance with `curl`:

```bash
hpc model ollama MODEL
curl http://localhost:11434/api/generate -d '{"model": "MODEL", "prompt": "Hello", "stream": false}'
```

### ComfyUI

- ComfyUI starts with ComfyUI-Manager and CORS enabled, in the workspace `~/comfy/ComfyUI`.
- Models go in `~/comfy/ComfyUI/models/<kind>/` (`checkpoints`, `loras`, `vae`, ...). **Do not use the "Download" button of the web interface**: it downloads to your computer through the browser. Download on the cluster with [`hpc model template NAME`](#model) (the models of a ComfyUI template, with no URL to copy), [`hpc model comfy --workflow FILE`](#model) (those of your workflow file) or [`hpc model comfy URL --to KIND`](#model), or copy a file you already have:

```bash
hpc model comfy "https://huggingface.co/ORG/REPO/resolve/main/model.safetensors" --to checkpoints
rsync -avP model.safetensors "$HPC_USER"@hpcgate.unical.it:comfy/ComfyUI/models/checkpoints/
```

- Check that the models fit the class: the GPU memory of `small` is 33 GB, and a workflow may need more than the sum of its files.
#### From the "Missing models" panel to the download

When a workflow is opened in ComfyUI, the panel "Missing models" lists the files it needs, each with a **Download** button. **Do not use it**: it downloads to your computer through the browser. Use the cluster instead:

1. Note the workflow you opened and the files the panel lists (name, folder and size).
2. On your machine, find the template: `hpc model template list --filter NAME` (for instance `--filter minimax`). Each row is a template with `[ ]`, `[~]` or `[x]` and `present/total`; pick the one whose model count matches the panel. A workflow of your own is a file: export it from the Workflow menu of ComfyUI and use it in the next step with `--workflow`.
3. Download everything it needs, in one job (give it a time limit that fits the size: the rate seen on the cluster is about 40 MB/s, which is roughly 15 minutes for 40 GB):

   ```bash
   hpc model template video_minimax_h3_i2v --time 02:00:00     # a ComfyUI template
   hpc model comfy --workflow my_workflow.json --time 02:00:00 # a workflow file of yours
   ```

   The command prints the free space and the total to download first, and downloads nothing if the total does not fit. If it stops half way, run it again: the files already complete are skipped.
4. Check the result: `hpc model template list --filter NAME` must show `[x]` for the template.
5. In the ComfyUI page, press the refresh icon of the "Missing models" panel (or reload the page): the models are now found. If ComfyUI was started before the download, a model list that stays stale is cured by reloading the page.
6. Run the workflow on a class whose GPU memory holds the models: the GPU memory of each class is in its profile name (`small` has 33 GB; `medium` 71 GB). The sum of the model files is a lower bound of what is needed.

- The results (videos, images) are written on the cluster, in `~/comfy/ComfyUI/output` (the video workflows use the `video/` sub-folder). To see them, use the `Save Video` node of the workflow, the queue panel (button in the top right, "Completed" tab) or the "Assets" tab; to copy them to your machine use [`hpc download comfy`](#download), for instance `hpc download comfy --latest 1`.
- Custom nodes installed from the Manager need Internet access from the compute node.

### Security

> [!WARNING]
> `serve` reaches the node through the head node, so the server listens on **all interfaces** of the node: other users of the cluster network can open the port. Jupyter is protected by its token; **ComfyUI and Ollama have no authentication**. Keep `--time` short, stop the service when you are done and do not process sensitive or personal data with it: the shared `/home` has no confidentiality guarantee.

### Problems

| Symptom                                            | Cause and action                                                                                                                  |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `ended before it started`                          | The job failed at once; read `hpc logs ID` (typically a missing program: run `hpc setup`)                                         |
| Connection reset or empty page, tunnel still open  | The server is still starting, or it stopped: read `hpc logs ID`. `serve` does not notice a job that dies after the tunnel is open |
| `hpc setup` prints `FAIL ... cannot reach`         | The compute node has no route to that site; report it to cluster support                                                          |
| `ExitOnForwardFailure` or "address already in use" | The local port is taken: use `--port N`                                                                                           |
| The server starts and stops at once                | The port is already in use on the node: use `--port N`                                                                            |

## 9. How it works

- Each command runs over SSH on `hpcgate.unical.it` after `module load slurm`, so `sbatch`, `squeue`, `sacct` and `scancel` are available.
- The commands share one SSH connection (`~/.ssh/hpc-*`), which stays open for 10 minutes after the last one, so only the first command pays for connecting. Sessions that need a terminal (`logs -f`, `queue -w`, `wait`, `shell`) and tunnels use a connection of their own.
- Only `submit` and `shell` run in a login shell, because a job inherits the environment it is started from (Conda included). The other commands skip it: the login shell runs your profile on the head node a second time, which costs about one second per command.
- The current local directory name defines the project: `~/Workspaces/university/hpc` ↔ `~/projects/hpc` on the cluster. Run commands from the same directory every time.
- `/home` is shared by the head node and both compute nodes, so files pushed from your machine are visible to jobs wherever they run.
- The head node is for access, editing and submission only; computation always happens through Slurm jobs.

```
bin/hpc                 the command
templates/demo.sbatch   smoke-test job
templates/job.sbatch    starting point for real jobs, with SIGTERM handling
tests/test_hpc.sh       offline test suite
```

## 10. Troubleshooting

Start with `hpc doctor`, which checks the most common causes below.

| Symptom                                          | Likely cause and action                                                                               |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `hpc: HPC_USER: set HPC_USER ...`                | Set `HPC_USER` in `.env` ([installation](#2-installation))                                            |
| SSH hangs or times out                           | The university OpenVPN is not connected, or its configuration was never requested through UniTicket   |
| `cd: projects/<name>: No such file or directory` | Run `hpc push` first, from the project directory                                                      |
| `module: command not found`                      | The login shell on the head node does not define `module`; report the exact error                     |
| Invalid or unauthorised QoS                      | Wrong spelling, no active booking, or the five-minute sync has not run yet; check `hpc qos`           |
| QoS limit error                                  | A booked QoS accepts one submitted job; also check running Jupyter kernels with `hpc queue`           |
| GPU request rejected                             | Only exact profiles are accepted; use the classes above rather than `--gpus=1`                        |
| Job `PENDING`                                    | Resources are busy; inspect the reason column in `hpc queue` and the live cluster status page         |
| Job `PREEMPTED` or kernel vanished               | The job used a preemptible QoS; reload checkpoints or use a booking                                   |
| `OUT_OF_MEMORY`                                  | System RAM exhausted: raise `--mem` (or choose a larger class); do not confuse with GPU-memory errors |
| `hpc: no log found`                              | The job has not written output yet, or the output name does not end with `-<id>.out`                  |

When contacting cluster support, include the job ID, approximate time, the exact `hpc submit` command, the effective QoS and the relevant log excerpt. Never include passwords or tokens.

## 11. Tests

```bash
bash tests/test_hpc.sh                          # the hpc command
uv run python -m unittest discover -s tests     # the interactive view
```

The Python tests cover the parsers of the interactive view on output captured from the cluster and drive the application with a fake cluster. The shell suite replaces `ssh`, `rsync` and `uv` with stubs and checks the commands that would be sent to the cluster (presets, QoS selection, quoting, argument validation, `.env` loading). It does not exercise the live cluster.

## Public page

The landing page lives in `docs/` and is published with GitHub Pages. Its stylesheet is compiled from Tailwind, so no third-party script is loaded. After editing `docs/index.html` or `site-src/`, rebuild it:

```bash
npx tailwindcss@3.4.17 -c site-src/tailwind.config.js -i site-src/input.css -o docs/style.css --minify
```

## Before you leave

- Save results and checkpoints to your home, and `hpc pull` what you need locally.
- Cancel jobs you no longer need (`hpc cancel ID`) and release or cancel unused bookings in the portal.

## License

Released under the [MIT License](license).
