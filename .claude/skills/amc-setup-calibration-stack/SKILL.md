---
name: "amc-setup-calibration-stack"
description: "Launch AutoMagicCalib microservice and web UI from NGC release images via Docker Compose. Use when user says 'launch auto calibration', 'launch AMC', 'start MS+UI', or 'set up auto-magic-calib'. Requires NGC API key."
metadata:
  author: "NVIDIA Metropolis Team"
  tags: [amc, deepstream, docker, calibration, setup, ngc]
  languages: [bash]
  domain: calibration
owner: "nvidia-metropolis-team"
service: "auto-magic-calib"
version: "1.0.0"
reviewed: "2026-04-28"
data_classification: public
---

# Skill: Launch AutoMagicCalib Release Containers

## Purpose
Launch the AutoMagicCalib microservice (MS) and UI from pre-built release images via Docker Compose. Use this for production deployments or when you want to run the full stack (backend + web UI) without building images locally.

## Prerequisites
- Docker and Docker Compose installed
- NVIDIA Docker Runtime configured (for GPU support)
- `auto-magic-calib` repo on disk — Step 0b auto-resolves an existing checkout via `git rev-parse --show-toplevel`, or offers to clone `https://github.com/NVIDIA-AI-IOT/auto-magic-calib` into `~/auto-magic-calib` if none is found
- NGC account with access to NVIDIA container registry
- **Docker must be runnable without `sudo`** — verify with `docker ps`. If it fails, ask the user to follow the post-install steps: https://docs.docker.com/engine/install/linux-postinstall/

> **If `docker ps` fails with "permission denied"**, ask the user to run:
> ```bash
> sudo usermod -aG docker $USER
> newgrp docker   # applies group change in current shell without logout
> ```
> Then verify with `docker ps` before continuing.

## Detailed Workflow

### Step 0: Verify Docker Runs Without sudo

```bash
docker ps
```

- If it succeeds → continue.
- If it fails with "permission denied" → the user is not in the `docker` group. Ask the user to run:
  ```bash
  sudo usermod -aG docker $USER && newgrp docker
  ```
  Then ask the user to confirm `docker ps` works before continuing.

> **Agent note**: If `docker ps` cannot be run from within the Claude Code sandbox, ask the user to confirm it works (e.g. "Can you confirm `docker ps` runs without sudo?") before proceeding.

### Step 0b: Resolve Repo Checkout

The skill needs `compose/`, `assets/sdg_08_2_sample_data_010926.zip`, and a `models/` mount point — all of which live in the `auto-magic-calib` repo. If you're already inside a checkout, the skill uses it. Otherwise it offers to clone (via AskUserQuestion) into `~/auto-magic-calib`.

```bash
REPO_URL="https://github.com/NVIDIA-AI-IOT/auto-magic-calib.git"
DEFAULT_CLONE_DIR="$HOME/auto-magic-calib"

# 1. Already inside a usable checkout?
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/compose/compose.yml" ] && [ -d "$REPO_ROOT/assets" ]; then
  echo "✓ Using existing checkout: $REPO_ROOT"

# 2. Default clone dir already populated from a prior run?
elif [ -d "$DEFAULT_CLONE_DIR/.git" ] && [ -f "$DEFAULT_CLONE_DIR/compose/compose.yml" ]; then
  REPO_ROOT="$DEFAULT_CLONE_DIR"
  echo "✓ Found existing clone at $REPO_ROOT"

# 3. Nothing on disk — clone (only after asking the user, see Agent note below).
else
  git clone "$REPO_URL" "$DEFAULT_CLONE_DIR"
  REPO_ROOT="$DEFAULT_CLONE_DIR"
fi

cd "$REPO_ROOT"
export REPO_ROOT
echo "REPO_ROOT=$REPO_ROOT"
```

> **Agent note**: do **not** clone silently. Ask the user via AskUserQuestion first — e.g. "auto-magic-calib repo not found. Clone `https://github.com/NVIDIA-AI-IOT/auto-magic-calib` into `~/auto-magic-calib`? (or provide your own path)". Honour an alternate path if the user offers one. The clone is a few hundred MB (compose files + sample dataset + assets).

### Step 0c: Install Python venv (New Systems Only)

On a fresh system, `pip` and `python3-venv` may not be available. Install them first:

```bash
sudo apt install -y python3-venv python3-pip

# Create a venv for HuggingFace CLI (project-local preferred)
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HF_VENV="${REPO_DIR}/venv"
python3 -m venv "$HF_VENV"

# Install HuggingFace hub (needed for VGGT download)
"$HF_VENV/bin/pip" install --upgrade pip huggingface_hub
```

> **Note**: Skip this step if a venv with `hf` already exists (check `venv/bin/hf` in the repo root or `~/venv/amc/bin/hf`).

### Step 1: Login to NGC

Ask the user for their NGC API key via AskUserQuestion, then run:

```bash
echo "<NGC_API_KEY>" | docker login nvcr.io --username '$oauthtoken' --password-stdin
echo "✓ NGC authentication complete"
```

### Step 2: Download VGGT Model (If Not Already Present)

```bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [ -f "models/vggt/vggt_1B_commercial.pt" ]; then
  echo "✓ VGGT model already present"
else
  echo "✗ VGGT model not found"
  echo "Options:"
  echo "  1. Continue without VGGT (AMC only - sufficient for most use cases)"
  echo "  2. Download VGGT model (~4.7GB, requires HuggingFace account)"
fi
```

**To download VGGT** (ask user for HuggingFace token via AskUserQuestion):

**Step 2a: Accept Model License** (required, one-time):
1. Visit: https://huggingface.co/facebook/VGGT-1B-Commercial
2. Log in to your HuggingFace account
3. Click "Agree and access repository" to accept license terms

**Step 2b: Get HuggingFace Token**:
1. Visit: https://huggingface.co/settings/tokens
2. Create new token with "Read" access (starts with `hf_...`)
3. Ask user for token via AskUserQuestion — do NOT ask them to run a command

**Step 2c: Download** (pass token inline, no interactive login needed):
```bash
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_DIR"

# Find the HuggingFace CLI binary (named 'hf', not 'huggingface-cli')
HF_BIN="$(find "$REPO_DIR/venv" ~/venv/amc -name hf -type f 2>/dev/null | head -1)"

"$HF_BIN" download facebook/VGGT-1B-Commercial \
  --local-dir models/vggt/ \
  --token <HF_TOKEN>

# Verify
ls -lh models/vggt/vggt_1B_commercial.pt
# Should show ~4.7GB file
```

> **Important**: Download BEFORE setting `chown 1000:1000` on the models directory — the current user needs write access during download. Set permissions in Step 4 after download completes.

### Step 3: Configure .env Variables

The `.env` file at `compose/.env` controls ports and paths. Update it before launching:

```bash
cd $REPO_ROOT/compose

# Find available backend port (8000-8009)
for port in {8000..8009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
    MS_PORT=$port
    echo "Using backend port: $MS_PORT"
    break
  fi
done

# Find available UI port (5000-5009)
for port in {5000..5009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
    UI_PORT=$port
    echo "Using UI port: $UI_PORT"
    break
  fi
done

# Get host IP
HOST_IP=$(hostname -I | awk '{print $1}')
echo "Host IP: $HOST_IP"

# Update .env file
cat > .env <<EOF
AUTO_MAGIC_CALIB_MS_PORT=${MS_PORT}
AUTO_MAGIC_CALIB_UI_PORT=${UI_PORT}
PROJECT_DIR=../../projects
MODEL_DIR=../../models
HOST_IP=${HOST_IP}
EOF

echo "✓ .env updated"
cat .env
```

**Important**: `HOST_IP` must be the machine's network IP (not `localhost`) so the UI container can reach the backend from a browser.

### Step 4: Set Directory Permissions

The containers run as UID/GID 1000. The `projects` and `models` directories must be owned by this UID for containers to read/write properly:

```bash
cd $REPO_ROOT

# Create projects directory if it doesn't exist
mkdir -p projects

# Set ownership (required for containers to write calibration outputs)
# Do this AFTER VGGT download is complete (current user needs write access during download)
sudo chown 1000:1000 -R projects
sudo chown 1000:1000 -R models

echo "✓ Permissions set"
```

### Step 5: Launch Services

```bash
cd $REPO_ROOT/compose

# Start all services (images pulled automatically on first run)
docker compose up -d

# Check containers are running
docker compose ps
```

**Expected output**:
```
NAME                    IMAGE                                                              STATUS
auto-magic-calib-ms-1   nvcr.io/nvidia/auto-magic-calib:2.0.0           Up (healthy)
auto-magic-calib-ui-1   nvcr.io/nvidia/auto-magic-calib-ui:2.0.0        Up
```

### Step 6: Verify Services Are Running

```bash
# Read ports from .env
MS_PORT=$(grep AUTO_MAGIC_CALIB_MS_PORT $REPO_ROOT/compose/.env | cut -d= -f2)
UI_PORT=$(grep AUTO_MAGIC_CALIB_UI_PORT $REPO_ROOT/compose/.env | cut -d= -f2)
HOST_IP=$(grep HOST_IP $REPO_ROOT/compose/.env | cut -d= -f2)

# Check containers are running (from any directory)
docker compose -f $REPO_ROOT/compose/compose.yml ps

# Check microservice health
curl -s http://localhost:${MS_PORT}/v1/ready
# Expected: {"code":0,"message":"VSS Auto Calibration Microservice is ready"}

# Check UI is serving
curl -s -o /dev/null -w "%{http_code}" http://localhost:${UI_PORT}
# Expected: 200

echo "Microservice: http://${HOST_IP}:${MS_PORT}"
echo "Web UI:       http://${HOST_IP}:${UI_PORT}"
```

## Success Criteria

**Both containers running**:
```bash
docker compose -f $REPO_ROOT/compose/compose.yml ps
# Both services should show "Up" status
# Microservice should show "(healthy)" in STATUS column
```

**Microservice healthy**:
```bash
MS_PORT=$(grep AUTO_MAGIC_CALIB_MS_PORT $REPO_ROOT/compose/.env | cut -d= -f2)
curl http://localhost:${MS_PORT}/v1/ready
# Returns: {"code":0,"message":"VSS Auto Calibration Microservice is ready"}
```

**Web UI accessible**:
- Open browser: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_UI_PORT>`
- Should display the AutoMagicCalib web interface
- Should be able to create projects and run calibration

## Key Output

**Microservice**: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_MS_PORT>` (default port 8000)
- API docs: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_MS_PORT>/docs`

**Web UI**: `http://<HOST_IP>:<AUTO_MAGIC_CALIB_UI_PORT>` (default port 5000)
- Interactive project management
- File upload interface
- Calibration configuration
- Real-time status monitoring
- Results visualization and download

**Data Persistence**:
- Projects stored: `$REPO_ROOT/projects/`
- State persisted: `$REPO_ROOT/projects/state.json`

## Troubleshooting

| Issue | Symptoms | Solution |
|-------|----------|----------|
| `pip` not found | `pip: command not found` | Run `sudo apt install -y python3.12-venv python3-pip` then create venv (Step 0) |
| `huggingface-cli` not found | `huggingface-cli: command not found` | The binary is named `hf` in the venv. Find it with: `find venv ~/venv/amc -name hf -type f 2>/dev/null \| head -1` |
| `python3 -m venv` fails | "ensurepip not available" | Run `sudo apt install -y python3.12-venv` first |
| Docker permission denied | "permission denied while trying to connect to docker socket" | User not in docker group — ask user to run: `sudo usermod -aG docker $USER && newgrp docker`. See: https://docs.docker.com/engine/install/linux-postinstall/ |
| NGC pull fails | "401 Unauthorized" on pull | Re-run NGC login: `echo "$NGC_API_KEY" \| docker login nvcr.io --username '$oauthtoken' --password-stdin` |
| VGGT download permission error | "PermissionError: [Errno 13] Permission denied: 'models/vggt/.cache'" | Download VGGT BEFORE setting `chown 1000:1000` on models. Fix: `sudo chown -R $(id -u):$(id -g) models` then re-download |
| Port already in use | "address already in use" | Find available port in 8000-8009 (MS) or 5000-5009 (UI); update `.env` |
| Permission denied (projects) | "Permission denied: 'projects/...'" in MS logs | Run: `sudo chown 1000:1000 -R projects` |
| Permission denied (models) | "Permission denied: 'models/...'" in MS logs | Run: `sudo chown 1000:1000 -R models` |
| UI can't reach backend | Browser shows connection error | Verify `HOST_IP` in `.env` is the machine's network IP, not `localhost` |
| VGGT model not found | Warning in MS logs about missing VGGT | Download model (Step 2) or ignore (AMC works without VGGT) |
| Container exits immediately | Status "Exited" | Check logs: `docker compose logs auto-magic-calib-ms` |
| GPU not available | "CUDA not available" in logs | Check NVIDIA runtime: `docker run --rm --runtime=nvidia --gpus all ubuntu:20.04 nvidia-smi` |
| "No such file or directory" when verifying | After launch, can't find compose directory | Working directory persists after `cd compose`. Use absolute paths or run `cd $REPO_ROOT` first |

**Common Fixes**:
```bash
cd $REPO_ROOT/compose

# View logs
docker compose logs -f

# View logs for specific service
docker compose logs -f auto-magic-calib-ms

# Restart all services
docker compose restart

# Stop and remove containers
docker compose down

# Update .env and relaunch
docker compose up -d

# Check container status from any directory
docker compose -f $REPO_ROOT/compose/compose.yml ps
```

## Stopping the Services

```bash
cd $REPO_ROOT/compose

# Stop all services (containers removed, data persisted)
docker compose down

# Stop and remove volumes
docker compose down -v
```

## Quick Reference for Agents

**To autonomously launch release containers**:

1. **Verify docker works without sudo**: run `docker ps`
   - If "permission denied" → tell user to run `sudo usermod -aG docker $USER && newgrp docker` and confirm it works before continuing (https://docs.docker.com/engine/install/linux-postinstall/)
   - If `docker ps` cannot be run from the sandbox → all subsequent Docker commands (NGC login, VGGT download, `docker compose up`) are also blocked. Ask the user to run the full Docker workflow in their terminal: NGC login, VGGT download if needed, update `.env` with all required variables (`AUTO_MAGIC_CALIB_MS_PORT`, `AUTO_MAGIC_CALIB_UI_PORT`, `HOST_IP`, `PROJECT_DIR`, `MODEL_DIR`), set permissions (`sudo chown 1000:1000 -R projects models`), and run `docker compose up -d`.
2. **Resolve repo**: if `git rev-parse --show-toplevel` returns a path containing `compose/compose.yml`, use it. Else if `~/auto-magic-calib/compose/compose.yml` exists, use that. Else ask the user via AskUserQuestion whether to clone `https://github.com/NVIDIA-AI-IOT/auto-magic-calib` into `~/auto-magic-calib` (or a path they specify), then `git clone` and `cd` into it. Export `REPO_ROOT`.
3. **Check venv**: look for `hf` binary in `<repo>/venv/bin/hf` or `~/venv/amc/bin/hf`; if neither exists → run Step 0c
4. **NGC Login**: ask user for NGC API key via AskUserQuestion, then:
   - `echo "<key>" | docker login nvcr.io --username '$oauthtoken' --password-stdin`
5. **Check for VGGT model** (`models/vggt/vggt_1B_commercial.pt`):
   - If found → continue
   - If not found → **MUST ask the user** via AskUserQuestion before continuing: "VGGT model not found. Some test datasets require VGGT (`run_vggt: true`). Download it now? (~4.7GB, requires HuggingFace token) — if skipped, those tests will fail."
     - If yes → ask for HF token via AskUserQuestion, then find `hf` binary and run: `<hf_bin> download facebook/VGGT-1B-Commercial --local-dir models/vggt/ --token <HF_TOKEN>`
     - If no → continue (AMC-only mode, datasets with `run_vggt: true` will fail)
6. Find available ports (MS: 8000-8009, UI: 5000-5009)
7. Get host IP: `hostname -I | awk '{print $1}'`
8. Update `.env`: set `AUTO_MAGIC_CALIB_MS_PORT`, `AUTO_MAGIC_CALIB_UI_PORT`, `HOST_IP`
9. Set permissions (AFTER VGGT download): `mkdir -p projects && sudo chown 1000:1000 -R projects models`
   > **Agent note**: If `sudo` cannot be run from within the Claude Code sandbox, ask the user to run this command in their terminal before proceeding to launch.
10. Launch: `cd compose && docker compose up -d`
11. Verify: `curl http://localhost:${MS_PORT}/v1/ready`
12. Return URLs to user: `http://<HOST_IP>:<MS_PORT>` and `http://<HOST_IP>:<UI_PORT>`

**Example autonomous execution**:
```bash
# Step 0: Verify docker works without sudo
docker ps || { echo "ERROR: Docker requires sudo. Ask user to run: sudo usermod -aG docker \$USER && newgrp docker"; exit 1; }

# Step 0b: Resolve repo (clone only AFTER asking the user via AskUserQuestion)
REPO_URL="https://github.com/NVIDIA-AI-IOT/auto-magic-calib.git"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_DIR" ] || [ ! -f "$REPO_DIR/compose/compose.yml" ]; then
  REPO_DIR="$HOME/auto-magic-calib"
  [ -d "$REPO_DIR/.git" ] || git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

# Step 0c: Ensure venv + hf CLI exist (new systems)
HF_BIN="$(find "$REPO_DIR/venv" ~/venv/amc -name hf -type f 2>/dev/null | head -1)"
if [ -z "$HF_BIN" ]; then
  sudo apt install -y python3-venv python3-pip
  python3 -m venv "$REPO_DIR/venv"
  "$REPO_DIR/venv/bin/pip" install --upgrade pip huggingface_hub
  HF_BIN="$REPO_DIR/venv/bin/hf"
fi

# Step 1: NGC login (ask user for key via AskUserQuestion, then:)
echo "<NGC_API_KEY>" | docker login nvcr.io --username '$oauthtoken' --password-stdin

# Step 2: Download VGGT if needed (ask user for HF token via AskUserQuestion, then:)
if [ ! -f models/vggt/vggt_1B_commercial.pt ]; then
  "$HF_BIN" download facebook/VGGT-1B-Commercial \
    --local-dir models/vggt/ \
    --token <HF_TOKEN>
fi

# Step 3: Find available ports
for port in {8000..8009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then MS_PORT=$port; break; fi
done
for port in {5000..5009}; do
  if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then UI_PORT=$port; break; fi
done
HOST_IP=$(hostname -I | awk '{print $1}')

# Step 4: Update .env
cat > compose/.env <<EOF
AUTO_MAGIC_CALIB_MS_PORT=${MS_PORT}
AUTO_MAGIC_CALIB_UI_PORT=${UI_PORT}
PROJECT_DIR=../../projects
MODEL_DIR=../../models
HOST_IP=${HOST_IP}
EOF

# Step 5: Set permissions (after VGGT download)
mkdir -p projects
sudo chown 1000:1000 -R projects models

# Step 6: Launch
cd compose && docker compose up -d
sleep 5

# Step 7: Verify
docker compose ps
curl -s http://localhost:${MS_PORT}/v1/ready
# Expected: {"code":0,"message":"VSS Auto Calibration Microservice is ready"}

echo "Microservice: http://${HOST_IP}:${MS_PORT}"
echo "Web UI:       http://${HOST_IP}:${UI_PORT}"
```

**For agents using AskUserQuestion tool**:

When NGC authentication is needed:
```
AskUserQuestion:
  question: "NGC authentication is required to pull container images. Please provide your NGC API key."
  instruction: "Get your NGC API key from https://org.ngc.nvidia.com/setup/api-key"

Then run:
  echo "<user_provided_key>" | docker login nvcr.io --username '$oauthtoken' --password-stdin
```

When VGGT model is not found:
```
AskUserQuestion:
  question: "VGGT model not found. VGGT provides model-based refinement (optional). Download it?"
  options:
    - "No, continue with AMC only (recommended)"
    - "Yes, download VGGT (~4.7GB, requires HuggingFace token)"

If "Yes":
  AskUserQuestion:
    question: "Please provide your HuggingFace token (hf_...). First accept the license at huggingface.co/facebook/VGGT-1B-Commercial"
    # User provides token via Other text field

  Then run (NO interactive login needed — pass token inline):
    # Find hf binary
    HF_BIN="$(find venv ~/venv/amc -name hf -type f 2>/dev/null | head -1)"
    "$HF_BIN" download facebook/VGGT-1B-Commercial \
      --local-dir models/vggt/ \
      --token <user_provided_token>
```

## Related Skills
- `.claude/skills/amc-run-sample-calibration/SKILL.md` - Sanity-check the running stack with the bundled sample dataset
- `.claude/skills/amc-run-video-calibration/SKILL.md` - Calibrate from your own pre-recorded MP4s via REST API
- `.claude/skills/amc-run-rtsp-calibration/SKILL.md` - Calibrate from live RTSP streams via VIOS
