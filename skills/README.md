# AutoMagicCalib Skills Catalog

Structured skills for AI coding assistants working with AutoMagicCalib. Each skill is a self-contained markdown file under `skills/<name>/SKILL.md` documenting one executable capability — prerequisites, exact commands, success criteria, and troubleshooting.

## Runtime Requirements

The setup and calibration skills operate a real AutoMagicCalib stack. Runtime execution requires an NVIDIA GPU with NVENC, NVIDIA driver, Docker without sudo, NVIDIA Container Toolkit, and NGC image access. Optional VGGT refinement also requires HuggingFace access and the VGGT model. In restricted or no-GPU sandboxes, use the skills for planning and command preparation only; do not mark calibration as validated unless it ran on a suitable host.

Typical runtime depends on image pulls, model downloads, video length, and detector choice. The bundled sample can take several minutes up to about 30 minutes; custom videos can take 10-60+ minutes; VGGT refinement usually adds a few minutes when enabled.

## Available Skills

**[amc-setup-calibration-stack](amc-setup-calibration-stack/SKILL.md)** — Launch the AMC microservice + web UI from NGC release images via Docker Compose. Auto-resolves an existing repo checkout (or offers to clone `https://github.com/NVIDIA-AI-IOT/auto-magic-calib`), then handles NGC login, optional VGGT download, `compose/.env` config (port/HOST_IP), UID 1000 permissions, and health verification. Returns MS, Swagger, and UI URLs.

**[amc-run-sample-calibration](amc-run-sample-calibration/SKILL.md)** — End-to-end sanity check on the shipped sample (`assets/sdg_08_2_sample_data_010926.zip`, 4 synthetic warehouse cameras with GT). Drives the REST API via a self-contained Python script; also documents the Swagger UI walkthrough as an alternative.

**[amc-run-video-calibration](amc-run-video-calibration/SKILL.md)** — Calibrate a camera rig from pre-recorded **MP4 files**. Full API sequence (create project → upload files → verify → calibrate → poll → results), plus manual-alignment UI fallback and optional VGGT refinement.

**[amc-run-rtsp-calibration](amc-run-rtsp-calibration/SKILL.md)** — Calibrate a camera rig from live **RTSP streams**. VIOS records fixed-duration clips, AMC ingests them into the project, then the flow continues through verify → calibrate → poll → results.

## Installing Skills

Copy the AMC skill directories into the skills folder used by your coding assistant. Examples:

```bash
# Claude Code user-level
mkdir -p ~/.claude/skills
cp -r skills/amc-* ~/.claude/skills/

# Codex user-level
mkdir -p ~/.codex/skills
cp -r skills/amc-* ~/.codex/skills/

# Workspace-level example
mkdir -p <workspace>/.cursor/skills
cp -r skills/amc-* <workspace>/.cursor/skills/
```

Restart or reopen the coding assistant after copying the skills.

## Typical Flow

1. **First-time setup**: run `amc-setup-calibration-stack` to bring up MS + UI (clones the repo if you don't already have one on disk).
2. **Verify install**: run `amc-run-sample-calibration` on the bundled sample.
3. **Calibrate your own data**:
   - Pre-recorded MP4s → `amc-run-video-calibration`
   - Live RTSP cameras → `amc-run-rtsp-calibration`

## Example Prompts

```text
launch auto calibration
```

```text
calibrate sample dataset
```

```text
calibrate these videos - /path/to/NV-Warehouse-4Cam/videos
```

```text
calibrate these streams - rtsp://<host>:<port>/<path>/cam_00.mp4, rtsp://<host>:<port>/<path>/cam_01.mp4, rtsp://<host>:<port>/<path>/cam_02.mp4. Use resnet; I will upload alignment/layout/settings in the UI.
```

## Manual Use

Each `SKILL.md` can also be used as a runbook with copy-paste commands and Python scripts. For the full product walkthrough, use the root `README.md` sections for quick start, sample data setup, and UI calibration.
