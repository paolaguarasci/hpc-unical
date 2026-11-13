# hpc

Command-line helpers for the **UniCal HPC cluster**. A single command, `hpc`, runs on your own machine and drives the cluster over SSH: submit Slurm jobs with sensible presets, watch the queue, sync files and read logs, without opening a portal shell.

> **Status.** The test suite passes offline (stubs for `ssh` and `rsync`). The tool has not yet been validated against the live cluster; report any discrepancy.

Official reference: [Getting started with the UniCal HPC cluster](https://hpcgate.unical.it:8001/public/status/getting-started.html).

---

## Contents

- [hpc](#hpc)
  - [Contents](#contents)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Installation](#2-installation)
  - [3. Quick start](#3-quick-start)
  - [4. Command reference](#4-command-reference)
    - [`submit`](#submit)
    - [`queue`](#queue)
    - [`qos`](#qos)
    - [`push` and `pull`](#push-and-pull)
    - [`logs`](#logs)
    - [`cancel`](#cancel)
  - [5. Resource classes](#5-resource-classes)
  - [6. QoS, bookings and preemption](#6-qos-bookings-and-preemption)
  - [7. Writing your own job](#7-writing-your-own-job)
  - [8. How it works](#8-how-it-works)
  - [9. Troubleshooting](#9-troubleshooting)
  - [10. Tests](#10-tests)
  - [Before you leave](#before-you-leave)

---

## 1. Prerequisites

- A cluster account and the **university OpenVPN** connection, active whenever you run `hpc`.
- `ssh` access to `hpcgate.unical.it` with your cluster login (key-based login is strongly recommended, otherwise every command asks for the password).
- `bash`, `ssh` and `rsync` on your machine (the stock macOS versions are sufficient).

## 2. Installation

```bash
# 1. Make the command available on your PATH (adapt the target directory if needed)
ln -s "$PWD/bin/hpc" ~/.local/bin/hpc

# 2. Tell the tool who you are: set your cluster login in the .env file at the repository root
echo 'HPC_USER=your_cluster_login' > .env
```

`HPC_USER` is mandatory: the command fails immediately if it is set neither in `.env` nor in the environment. A variable already exported in your shell takes precedence over `.env`. The file is located through the symlink, so `hpc` works from any directory, and it is git-ignored (and therefore not pushed to the cluster). The cluster host (`hpcgate.unical.it`) is fixed.

## 3. Quick start

Run a five-second smoke test on the smallest GPU slice. Run these commands **from the repository root**.

```bash
hpc qos                                              # 1. check which QoS your account may use
hpc push                                             # 2. copy this directory to ~/projects/hpc on the cluster
hpc submit tiny --time 00:05:00 templates/demo.sbatch   # 3. submit; Slurm prints "Submitted batch job N"
hpc queue                                            # 4. PENDING -> RUNNING -> COMPLETED
hpc logs                                             # 5. read the output of the latest job
```

The demo prints the job ID, the home directory, the working directory, the compute node (`ainode01` or `ainode02`) and `CUDA_VISIBLE_DEVICES`. For a run without a GPU, replace `tiny` with `cpu`.

## 4. Command reference

| Command                                      | Purpose                                                          |
| -------------------------------------------- | ---------------------------------------------------------------- |
| `hpc submit CLASS --time T [options] SCRIPT` | Submit a batch script with the preset of `CLASS`                 |
| `hpc queue`                                  | Your pending and running jobs, plus the last 24 hours of history |
| `hpc qos`                                    | QoS associations granted to your account                         |
| `hpc push`                                   | Sync the current directory to the cluster                        |
| `hpc pull PATH...`                           | Fetch files from the cluster project directory                   |
| `hpc logs [ID] [-f]`                         | Show or follow a job's output                                    |
| `hpc cancel ID`                              | Cancel a job                                                     |
| `hpc help`                                   | Print usage                                                      |

### `submit`

```bash
hpc submit CLASS --time HH:MM:SS [--booked] [--requeue] [--cpus N] [--mem SIZE] SCRIPT
```

| Option                   | Meaning                                                                                                                |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `CLASS`                  | `tiny`, `small`, `medium`, `large` or `cpu` (see [section 5](#5-resource-classes))                                     |
| `--time T`               | **Required.** Wall-clock limit, e.g. `00:30:00` or `1-12:00:00`. The partition has no default limit, so always set one |
| `--booked`               | Use the protected QoS `gpu_<class>_reserved` (requires an active booking). Not available for `cpu`                     |
| `--requeue`              | Allow Slurm to put the job back in the queue after preemption. Use only if restarting the script is safe               |
| `--cpus N`, `--mem SIZE` | Override the class defaults (e.g. `--mem 48G`)                                                                         |
| `SCRIPT`                 | Path **relative to the project directory**, e.g. `job.sbatch` or `templates/demo.sbatch`                               |

Examples:

```bash
hpc submit small --time 02:00:00 train.sbatch                 # preemptible, no booking
hpc submit medium --time 12:00:00 --requeue train.sbatch      # restartable after preemption
hpc submit large --booked --time 24:00:00 train.sbatch        # protected, needs a Large booking
hpc submit cpu --time 00:10:00 --cpus 4 preprocess.sbatch     # CPU only
```

The command always adds `--partition=aiq --nodes=1 --ntasks=1` and the profile as `--gres=gpu:<profile>:1`. Resources and QoS given on the command line override any `#SBATCH` line in the script, so keep them out of your scripts.

### `queue`

Prints `squeue` for your user (job ID, name, state, elapsed time, **effective QoS**, node or pending reason) followed by `sacct` for the last 24 hours. Jupyter kernels are Slurm jobs and appear here too.

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
- **Preemption** can stop a job at any time. Slurm does not save state: your application must write checkpoints and reload them when restarted. See the SIGTERM handling in `templates/job.sbatch`.

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
hpc submit small --time 04:00:00 --requeue train.sbatch
hpc queue
hpc logs -f
hpc pull checkpoints/latest.pt results.csv
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

| Symptom                                          | Likely cause and action                                                                               |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `hpc: HPC_USER: set HPC_USER ...`                | Export `HPC_USER` ([installation](#2-installation))                                                   |
| SSH hangs or times out                           | OpenVPN is not connected                                                                              |
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
bash tests/test_hpc.sh
```

The suite replaces `ssh` and `rsync` with stubs and checks the commands that would be sent to the cluster (presets, QoS selection, quoting, argument validation). It does not exercise the live cluster.

## Before you leave

- Save results and checkpoints to your home, and `hpc pull` what you need locally.
- Cancel jobs you no longer need (`hpc cancel ID`) and release or cancel unused bookings in the portal.
