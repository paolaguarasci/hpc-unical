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
[![Tests: offline suite](https://img.shields.io/badge/tests-offline%20suite-brightgreen)](#10-tests)

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
| **Monitoring**      | `top` (interactive view), `queue -w`, `logs -f`, `wait`, `qos`, `cancel`                        |
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
    - [`queue`](#queue)
    - [`top`](#top)
    - [`qos`](#qos)
    - [`push` and `pull`](#push-and-pull)
    - [`logs`](#logs)
    - [`cancel`](#cancel)
    - [`shell`](#shell)
    - [`tunnel`](#tunnel)
    - [`wait`](#wait)
    - [`doctor`](#doctor)
  - [5. Resource classes](#5-resource-classes)
  - [6. QoS, bookings and preemption](#6-qos-bookings-and-preemption)
  - [7. Writing your own job](#7-writing-your-own-job)
  - [8. How it works](#8-how-it-works)
  - [9. Troubleshooting](#9-troubleshooting)
  - [10. Tests](#10-tests)
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

| Command                                      | Purpose                                                          |
| -------------------------------------------- | ---------------------------------------------------------------- |
| `hpc submit CLASS --time T [options] SCRIPT` | Submit a batch script with the preset of `CLASS`                 |
| `hpc queue [-w [SECONDS]]`                   | Your pending and running jobs, plus the last 24 hours of history |
| `hpc top`                                    | Interactive view of the cluster and of your jobs (requires `uv`) |
| `hpc qos`                                    | QoS associations granted to your account                         |
| `hpc push`                                   | Sync the current directory to the cluster                        |
| `hpc pull PATH...`                           | Fetch files from the cluster project directory                   |
| `hpc logs [ID] [-f]`                         | Show or follow a job's output                                    |
| `hpc cancel ID`                              | Cancel a job                                                     |
| `hpc shell CLASS --time T [options]`         | Interactive shell on a compute node with the preset of `CLASS`   |
| `hpc tunnel ID PORT`                         | Forward a local port to a server run by job `ID`                 |
| `hpc wait ID`                                | Block until job `ID` ends; succeed only if it completed          |
| `hpc doctor`                                 | Check tools, VPN and SSH access, Slurm and the project directory |
| `hpc help`                                   | Print usage                                                      |

### `submit`

```bash
hpc submit CLASS --time HH:MM:SS [--booked] [--requeue] [--cpus N] [--mem SIZE] SCRIPT [-- SBATCH_OPTION...]
```

| Option                   | Meaning                                                                                                                |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `CLASS`                  | `tiny`, `small`, `medium`, `large` or `cpu` (see [section 5](#5-resource-classes))                                     |
| `--time T`               | **Required.** Wall-clock limit, e.g. `00:30:00` or `1-12:00:00`. The partition has no default limit, so always set one |
| `--booked`               | Use the protected QoS `gpu_<class>_reserved` (requires an active booking). Not available for `cpu`                     |
| `--requeue`              | Allow Slurm to put the job back in the queue after preemption. Use only if restarting the script is safe               |
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
```

The command always adds `--partition=aiq --nodes=1 --ntasks=1` and the profile as `--gres=gpu:<profile>:1`. Resources and QoS given on the command line override any `#SBATCH` line in the script, so keep them out of your scripts. The options after `--` are placed after the presets and are not validated: a repeated option (for instance a second `--mem`) replaces the preset. In a job array, each task gets the resources of the class, and `%x-%j.out` gives each task a log of its own.

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

| Key            | Action                                                        |
| -------------- | ------------------------------------------------------------- |
| `Up` / `Down`  | Highlight a job; the log panel follows it                     |
| `Tab`          | Move between the job list, the log and the history            |
| `c`            | Cancel the highlighted pending or running job, after a prompt |
| `l`            | Open the whole log in `less` on the cluster (`q` to return)   |
| `t`            | Open an SSH tunnel to a port of the highlighted running job, or close it |
| `r`            | Refresh now                                                   |
| `q`            | Quit                                                          |

**Alerts.** While the view is open, a notification is raised when one of your jobs starts, ends (with its final state and exit code) or has used 90% of its time limit. On macOS it is also sent to the notification centre.

**Tunnels.** `t` asks for a port and forwards `localhost:<port>` to the same port on the node of the job, through the head node; the address appears in the job list, followed by `✓` when a server answers on that port or by `✗ no server` when nothing listens there (check the port in the log). Tunnels are closed when the job ends or the view is quit.

The view is a [Textual](https://textual.textualize.io/) application (`hpc_top/`) that runs on your machine; it requires [`uv`](https://docs.astral.sh/uv/), which installs the Python dependencies on first use. Each refresh is one SSH command, and all of them share a single multiplexed connection; refreshes never overlap, and a command that gets no answer within 30 seconds is stopped and reported. The pager and the tunnels use connections of their own.

### `qos`

Shows the QoS names your account is associated with. After a booking starts, allow up to five minutes for the new QoS to appear.

### `push` and `pull`

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
```

The lookup relies on the default naming `slurm-<id>.out` or the `%x-<id>.out` pattern used by the templates.

### `cancel`

```bash
hpc cancel 4821
```

### `shell`

```bash
hpc shell CLASS --time HH:MM:SS [--booked] [--cpus N] [--mem SIZE] [-- SRUN_OPTION...]
```

Opens an interactive shell on a compute node (`srun --pty bash -l`), with the same presets, QoS rules and options as `submit`; it starts in the project directory, so run `hpc push` first. Use it to build or test an environment instead of working on the head node. The session is a Slurm job: it is preemptible unless booked, it ends at the time limit, and it holds its resources until you leave it with `exit`.

```bash
hpc shell cpu --time 00:30:00          # one core, to try a Conda environment
hpc shell tiny --time 01:00:00         # with the smallest GPU slice
```

### `tunnel`

```bash
hpc tunnel 4821 8000     # http://localhost:8000 -> port 8000 on the node that runs job 4821
```

Forwards `localhost:PORT` to the same port of the compute node of a running job, through the head node, until Ctrl-C. The command fails when the job has no node (pending or finished) or when the local port is already in use. It does not check that a server listens on the remote port: a connection that is reset at once means that nothing does (the `t` key of `hpc top` performs that check).

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

## 8. How it works

- Each command opens an SSH session to `hpcgate.unical.it` and runs a login shell with `module load slurm`, so `sbatch`, `squeue`, `sacct` and `scancel` are available.
- The current local directory name defines the project: `~/Workspaces/university/hpc` ↔ `~/projects/hpc` on the cluster. Run commands from the same directory every time.
- `/home` is shared by the head node and both compute nodes, so files pushed from your machine are visible to jobs wherever they run.
- The head node is for access, editing and submission only; computation always happens through Slurm jobs.

```
bin/hpc                 the command
templates/demo.sbatch   smoke-test job
templates/job.sbatch    starting point for real jobs, with SIGTERM handling
tests/test_hpc.sh       offline test suite
```

## 9. Troubleshooting

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

## 10. Tests

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
