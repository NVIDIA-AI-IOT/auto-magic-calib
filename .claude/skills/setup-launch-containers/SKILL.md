---
name: "setup-launch-containers"
description: "Launch AutoMagicCalib microservice and web UI from NGC release images via Docker Compose. Use when user says 'launch auto calibration', 'launch AMC', 'start MS+UI', or 'set up auto-magic-calib'. Requires NGC API key."
metadata:
  author: "NVIDIA AutoMagicCalib Team"
  tags: [amc, deepstream, docker, calibration, setup, ngc]
  languages: [bash]
  domain: calibration
service: "auto-magic-calib"
version: "1.0.0"
---

# Skill: Launch AutoMagicCalib Containers

## Purpose
Stand up the AutoMagicCalib microservice (MS) and web UI from the pre-built NGC release images via Docker Compose. This is the prerequisite for every other AMC skill.

## Prerequisites
- x86_64 host with Ubuntu 24.04, NVIDIA GPU (NVENC-capable), driver 590
- Docker + NVIDIA Container Toolkit installed
- **Docker must run without `sudo`** — verify with `docker ps`
- NGC account with access to the NVIDIA container registry
- Repo cloned: `$REPO_ROOT/` (e.g. `/home/<user>/auto-magic-calib`)

> **If `docker ps` fails with "permission denied"**, ask the user to run:
> ```bash
> sudo usermod -aG docker $USER
> newgrp docker
> ```
> then confirm `docker ps` succeeds before continuing. See: https://docs.docker.com/engine/install/linux-postinstall/

## Detailed Workflow

### Step 0: Verify Docker Works Without sudo

```bash
docker ps
```

If this fails inside the Claude Code sandbox, ask the user to confirm `docker ps` works in their terminal before proceeding — every subsequent Docker command will also be blocked otherwise.

### Step 1: Login to NGC

NGC authentication is required to pull the release images. Ask the user for their NGC API key via `AskUserQuestion` (link them to https://org.ngc.nvidia.com/setup/api-key), then run:

```bash
echo "<NGC_API_KEY>" | docker login nvcr.io --username '$oauthtoken' --password-stdin
```

### Step 2: (Optional) Download VGGT Model

VGGT enables model-based refinement on top of geometry-based AMC. It's optional — **AMC works fine without it**.

```bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [ -f "models/vggt/vggt_1B_commercial.pt" ]; then
  echo "VGGT model already present"
else
  echo "VGGT model not found — ask user whether to download"
fi
```

If the user wants VGGT:

1. They must accept the model license at https://huggingface.co/facebook/VGGT-1B-Commercial (one-time).
2. They need a HuggingFace read token from https://huggingface.co/settings/tokens.
3. Ask for the token via `AskUserQuestion`, then:

```bash
# Ensure a venv with the HuggingFace CLI exists (create if needed)
if [ ! -x "$REPO_ROOT/venv/bin/hf" ] && [ ! -x ~/venv/amc/bin/hf ]; then
  sudo apt install -y python3-venv python3-pip
  python3 -m venv "$REPO_ROOT/venv"
  "$REPO_ROOT/venv/bin/pip" install --upgrade pip huggingface_hub
fi
HF_BIN="$(find "$REPO_ROOT/venv" ~/venv/amc -name hf -type f 2>/dev/null | head -1)"

"$HF_BIN" download facebook/VGGT-1B-Commercial \
  --local-dir "$REPO_ROOT/models/vggt/" \
  --token <HF_TOKEN>

ls -lh "$REPO_ROOT/models/vggt/vggt_1B_commercial.pt"  # ~4.7 GB
```

> **Order matters**: Download VGGT **before** `chown 1000:1000` (Step 4) — the current user needs write access during download.

### Step 3: Configure `compose/.env`

```bash
cd "$REPO_ROOT/compose"

# Find an available backend port (8000-8009)
for port in {8000..8009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
    MS_PORT=$port; break
  fi
done

# Find an available UI port (5000-5009)
for port in {5000..5009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
    UI_PORT=$port; break
  fi
done

# Reachable network IP (NOT localhost — browser must reach this from outside the UI container)
HOST_IP=$(hostname -I | awk '{print $1}')

cat > .env <<EOF
AUTO_MAGIC_CALIB_MS_PORT=${MS_PORT}
AUTO_MAGIC_CALIB_UI_PORT=${UI_PORT}
HOST_IP=${HOST_IP}
EOF

cat .env
```

`PROJECT_DIR` and `MODEL_DIR` are left at their compose defaults (`../../projects` and `../../models`, resolved from `compose/ms/compose.yml`), which map to `$REPO_ROOT/projects` and `$REPO_ROOT/models`. Add them to `.env` only if you want to point at non-default directories.

### Step 4: Set Directory Permissions

The containers run as UID/GID 1000. `projects/` and `models/` must be owned by that UID:

```bash
cd "$REPO_ROOT"
mkdir -p projects
sudo chown 1000:1000 -R projects models
```

> **Agent note**: if `sudo` is blocked inside the sandbox, ask the user to run this in their terminal before launching.

### Step 5: Launch Services

```bash
cd "$REPO_ROOT/compose"
docker compose up -d
docker compose ps
```

Expected:

```
NAME                    IMAGE                                        STATUS
auto-magic-calib-ms-1   nvcr.io/nvidia/auto-magic-calib:2.0.0        Up (healthy)
auto-magic-calib-ui-1   nvcr.io/nvidia/auto-magic-calib-ui:2.0.0     Up
```

First-run note: `docker compose up -d` pulls both images (several GB). The MS container's healthcheck has `start_period: 1000s` to allow model warm-up, so "starting" status for the first few minutes is normal.

### Step 6: Verify Services

```bash
MS_PORT=$(grep AUTO_MAGIC_CALIB_MS_PORT "$REPO_ROOT/compose/.env" | cut -d= -f2)
UI_PORT=$(grep AUTO_MAGIC_CALIB_UI_PORT "$REPO_ROOT/compose/.env" | cut -d= -f2)
HOST_IP=$(grep HOST_IP "$REPO_ROOT/compose/.env" | cut -d= -f2)

# Microservice health
curl -s "http://localhost:${MS_PORT}/v1/ready"
# Expected: {"code":0,"message":"VSS Auto Calibration Microservice is ready"}

# UI HTTP code
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:${UI_PORT}"
# Expected: 200

echo "Microservice: http://${HOST_IP}:${MS_PORT}"
echo "Swagger docs: http://${HOST_IP}:${MS_PORT}/docs"
echo "Web UI:       http://${HOST_IP}:${UI_PORT}"
```

## Success Criteria

- `docker compose ps` shows both containers `Up`, MS marked `(healthy)`.
- `curl http://localhost:${MS_PORT}/v1/ready` returns `{"code":0,...}`.
- `http://<HOST_IP>:<UI_PORT>` loads the AutoMagicCalib web interface in a browser.

## Key Output

- **Microservice**: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_MS_PORT>`
- **Swagger / OpenAPI docs**: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_MS_PORT>/docs`
- **Web UI**: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_UI_PORT>`
- **Project data**: `$REPO_ROOT/projects/` (persists across restarts)

## Troubleshooting

| Issue | Symptom | Fix |
|---|---|---|
| Docker permission denied | `permission denied while trying to connect to docker socket` | `sudo usermod -aG docker $USER && newgrp docker` |
| `pip` / `python3-venv` missing | `command not found` during VGGT setup | `sudo apt install -y python3-venv python3-pip` |
| NGC pull fails (401) | `Error response from daemon: unauthorized` on `docker compose up` | Re-run `docker login nvcr.io` with a valid NGC API key |
| VGGT download "Permission denied" | `PermissionError: 'models/vggt/.cache'` | Download VGGT **before** the `chown 1000:1000` step. Recover with `sudo chown -R $(id -u):$(id -g) models` then retry. |
| Port already in use | `bind: address already in use` | Pick a free port in 8000–8009 (MS) or 5000–5009 (UI) and update `compose/.env` |
| `Permission denied` in MS logs writing to `projects/` | MS can't write outputs | `sudo chown 1000:1000 -R projects` |
| UI loads but can't reach backend | Browser console shows connection error to `localhost` | `HOST_IP` in `.env` must be the host's network IP, not `localhost` |
| VGGT warning in MS logs | `VGGT model not found` | Expected if you skipped Step 2. AMC still runs — ignore, or download VGGT and restart. |
| Container exits immediately | `docker compose ps` shows `Exited` | `docker compose logs auto-magic-calib-ms` to see the error |
| CUDA not available | `CUDA not available` in MS logs | Check NVIDIA Container Toolkit: `docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 nvidia-smi` |

### Common Commands

```bash
cd "$REPO_ROOT/compose"

docker compose logs -f                          # all services
docker compose logs -f auto-magic-calib-ms      # MS only
docker compose restart                          # restart both
docker compose down                             # stop and remove containers (data in projects/ persists)
docker compose down -v                          # also remove volumes
docker compose up -d                            # relaunch after editing .env
```

## Stopping

```bash
cd "$REPO_ROOT/compose" && docker compose down
```

Project data in `$REPO_ROOT/projects/` is preserved. Use `docker compose down -v` if you also want to wipe volumes.

## Quick Reference for Agents

1. `docker ps` — verify no-sudo; if blocked, instruct user.
2. Prompt for NGC API key via `AskUserQuestion`, then `docker login nvcr.io`.
3. Check `models/vggt/vggt_1B_commercial.pt`. If absent, ask via `AskUserQuestion` whether to download (~4.7 GB, needs HF token). AMC works without it.
4. Scan ports 8000–8009 (MS) and 5000–5009 (UI); write `compose/.env` with `AUTO_MAGIC_CALIB_MS_PORT`, `AUTO_MAGIC_CALIB_UI_PORT`, `HOST_IP=$(hostname -I | awk '{print $1}')`.
5. `mkdir -p projects && sudo chown 1000:1000 -R projects models` — **after** any VGGT download.
6. `cd compose && docker compose up -d`.
7. Verify: `curl http://localhost:${MS_PORT}/v1/ready` → `{"code":0,...}`.
8. Report MS URL, Swagger URL (`/docs`), and UI URL to the user.

## Related Skills

- `.claude/skills/test-sample-dataset/SKILL.md` — sanity-check the running stack on the shipped sample data.
- `.claude/skills/calibrate-new-dataset/SKILL.md` — calibrate your own videos via REST API.

See the root `README.md` "Quick Start" section for the human-readable version of this flow.
