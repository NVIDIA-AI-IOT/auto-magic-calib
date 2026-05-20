# Quick Reference for Agents

Condensed runbook for autonomously launching the AutoMagicCalib release containers. The canonical step-by-step lives in `../SKILL.md` under `## Instructions`; this file is the agent-facing summary, plus an example autonomous execution block and AskUserQuestion templates.

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

# Step 0b: Resolve repo. If nothing is on disk, STOP and ask the user via
# AskUserQuestion before cloning — do NOT run `git clone` silently from this
# block. Only after explicit confirmation, run the cloning step shown below.
REPO_URL="https://github.com/NVIDIA-AI-IOT/auto-magic-calib.git"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_DIR" ] || [ ! -f "$REPO_DIR/compose/compose.yml" ]; then
  REPO_DIR="$HOME/auto-magic-calib"
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "No checkout found. Ask the user (AskUserQuestion):"
    echo "  Clone $REPO_URL into $REPO_DIR? [y/N]"
    echo "On 'y' — run: git clone \"$REPO_URL\" \"$REPO_DIR\""
    exit 1
  fi
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

# Step 4: Update compose/.env — preserve existing keys, back up first.
ENV_FILE="compose/.env"
[ -f "$ENV_FILE" ] && cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
touch "$ENV_FILE"
set_env_key() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$ENV_FILE"
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}
set_env_key AUTO_MAGIC_CALIB_MS_PORT "${MS_PORT}"
set_env_key AUTO_MAGIC_CALIB_UI_PORT "${UI_PORT}"
set_env_key PROJECT_DIR "../../projects"
set_env_key MODEL_DIR "../../models"
set_env_key HOST_IP "${HOST_IP}"

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
