# AutoMagicCalib Skills Catalog

Structured skills for AI coding assistants working with AutoMagicCalib. Each skill is a self-contained markdown file under `skills/<name>/SKILL.md` documenting one executable capability — prerequisites, exact commands, success criteria, and troubleshooting.

## Available Skills

**[amc-setup-calibration-stack](amc-setup-calibration-stack/SKILL.md)** — Launch the AMC microservice + web UI from NGC release images via Docker Compose. Auto-resolves an existing repo checkout (or offers to clone `https://github.com/NVIDIA-AI-IOT/auto-magic-calib`), then handles NGC login, optional VGGT download, `compose/.env` config (port/HOST_IP), UID 1000 permissions, and health verification. Returns MS, Swagger, and UI URLs.

**[amc-run-sample-calibration](amc-run-sample-calibration/SKILL.md)** — End-to-end sanity check on the shipped sample (`assets/sdg_08_2_sample_data_010926.zip`, 4 synthetic warehouse cameras with GT). Drives the REST API via a self-contained Python script; also documents the Swagger UI walkthrough as an alternative.

**[amc-run-video-calibration](amc-run-video-calibration/SKILL.md)** — Calibrate a camera rig from pre-recorded **MP4 files**. Full API sequence (create project → upload files → verify → calibrate → poll → results), plus manual-alignment UI fallback and optional VGGT refinement.

## Typical Flow

1. **First-time setup**: run `amc-setup-calibration-stack` to bring up MS + UI (clones the repo if you don't already have one on disk).
2. **Verify install**: run `amc-run-sample-calibration` on the bundled sample.
3. **Calibrate your own data**: pre-recorded MP4s → `amc-run-video-calibration`

## For Humans

Each `SKILL.md` is also a readable runbook — copy-paste commands and the Python scripts directly into your terminal. The root `README.md` has the narrative version of the same flow ("Quick Start", "Sample Data Setup", "Calibration Workflow (UI)").
