# Claude Skills Catalog

Structured skills for AI coding assistants working with AutoMagicCalib. Each skill is a self-contained markdown file under `.claude/skills/<name>/SKILL.md` documenting one executable capability — prerequisites, exact commands, success criteria, and troubleshooting.

## Available Skills

**[setup-launch-containers](skills/setup-launch-containers/SKILL.md)** — Launch the AMC microservice + web UI from NGC release images via Docker Compose. Handles NGC login, optional VGGT download, `compose/.env` config (port/HOST_IP), UID 1000 permissions, and health verification. Returns MS, Swagger, and UI URLs.

**[test-sample-dataset](skills/test-sample-dataset/SKILL.md)** — End-to-end sanity check on the shipped sample (`assets/sdg_08_2_sample_data_010926.zip`, 4 synthetic warehouse cameras with GT). Drives the REST API via a self-contained Python script; also documents the Swagger UI walkthrough as an alternative.

**[calibrate-new-dataset](skills/calibrate-new-dataset/SKILL.md)** — Calibrate a new camera rig on user-supplied videos. Covers the full API sequence (create project → upload files → verify → calibrate → poll → results), handles the manual-alignment UI fallback, and includes the optional VGGT refinement step.

## Typical Flow

1. **First-time setup**: run `setup-launch-containers` to bring up MS + UI.
2. **Verify install**: run `test-sample-dataset` on the bundled sample.
3. **Calibrate your own data**: run `calibrate-new-dataset`.

## For Humans

Each `SKILL.md` is also a readable runbook — copy-paste commands and the Python scripts directly into your terminal. The root `README.md` has the narrative version of the same flow ("Quick Start", "Sample Data Setup", "Calibration Workflow (UI)").
