---
name: "amc-run-rtsp-calibration"
description: "Calibrate a new dataset from live RTSP camera streams via the AutoMagicCalib REST API. Use when the user provides RTSP URLs or asks to calibrate live cameras; VIOS records clips, AMC ingests them, then runs calibration."
owner: "NVIDIA CORPORATION"
service: "auto-magic-calib"
version: "1.0.0"
reviewed: "2026-06-15"
license: "Apache-2.0"
data_classification: public
metadata:
  tags: [amc, calibration, rtsp, vios, rest-api, camera, python]
---

# Skill: Calibrate from RTSP Streams

## When to Use This Skill

Activate this skill when the user wants to calibrate from live RTSP camera streams. Typical prompts:

- "calibrate RTSP streams" / "calibrate from live cameras"
- "run AMC on RTSP"
- The user provides one or more `rtsp://...` URLs

VIOS records fixed-duration clips from each stream, the AMC microservice ingests those clips into a project, then the workflow follows the same verification, calibration, polling, and results path as pre-recorded MP4 calibration.

Do not use this skill for local MP4 files already on disk; route those requests to `skills/amc-run-video-calibration/SKILL.md`. Do not use it for the bundled sample dataset; route that to `skills/amc-run-sample-calibration/SKILL.md`.

## Prerequisites

- [ ] AMC microservice and UI running (follow `skills/amc-setup-calibration-stack/SKILL.md` if needed).
- [ ] VIOS is running and reachable from the AMC microservice.
- [ ] `VIOS_BASE_URL` is configured in the AMC microservice environment before capture starts.
- [ ] RTSP URLs are reachable from the VIOS host.
- [ ] Camera streams have enough moving people/objects for calibration; record at least 2-3 minutes when possible.
- [ ] Python 3 with `requests` installed when using the bundled script.

## Data Privacy

RTSP URLs may contain usernames, passwords, hostnames, or network topology. Do not print full RTSP URLs if credentials are embedded. Pass VIOS tokens through environment variables or secure host prompts; do not echo tokens in chat, logs, or final answers.

## What to Ask the User

### Required

1. RTSP URLs, one per camera.
2. Camera names, one per stream. Use `cam_00`, `cam_01`, ... if the user does not provide names.
3. Recording duration in seconds. Minimum is `60`; prefer `120`-`180` or more when the scene has sparse motion.
4. Microservice URL, for example `http://<HOST_IP>:8000` or `http://<HOST_IP>:8000/v1`.
5. Project name.

### Auto-Detected or Asked

There is no local videos directory to anchor file discovery. Ask for the calibration settings file first. If supplied, scan that same directory for alignment and layout files:

| File | Candidate filenames | UI fallback |
|---|---|---|
| Calibration settings | User-provided path such as `settings.json`, `config.json`, or `calibration_config.json` | UI Step 3: Parameters |
| Alignment JSON | `alignment_data.json` in the settings file directory, or explicit user path | UI Step 4: Alignment |
| Layout PNG | `layout.png` in the settings file directory, or explicit user path | UI Step 4: Alignment |

Posting the settings file replaces UI Step 3 and may pin `detector` or `detector_type`. If it pins `resnet` or `transformer`, pass that same detector to `/calibrate`.

### Optional

6. `sensor_id` per stream if the cameras are already registered in VIOS. Leave unset for auto-registration.
7. Ground truth zip (`GT.zip`) for evaluation metrics.
8. Focal lengths, one per camera.
9. VIOS bearer token, if the VIOS deployment requires one.
10. Whether to run VGGT refinement after AMC completes, only when the project reports `vggt_state == "READY"`.

## Instructions

The bundled script in [scripts/run_rtsp_calibration.py](scripts/run_rtsp_calibration.py) implements this sequence end to end. Use the prose below for decisions, UI fallback, and troubleshooting.

### Step 0 - Verify AMC and VIOS

Confirm the AMC microservice is reachable:

```bash
curl -sf http://<HOST_IP>:<MS_PORT>/v1/ready
```

Confirm VIOS is reachable before starting capture. Probe in this order and stop at the first working URL:

```bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
VIOS_BASE_URL=""

# Default local VIOS port.
if curl -sf http://localhost:30888/vst/api/v1/sensor/list >/dev/null 2>&1; then
  HOST_IP=$(grep ^HOST_IP "$REPO_ROOT/compose/.env" 2>/dev/null | cut -d= -f2)
  VIOS_BASE_URL="http://${HOST_IP:-localhost}:30888"
  echo "VIOS detected at $VIOS_BASE_URL"
fi

# Running AMC microservice container environment.
if [ -z "$VIOS_BASE_URL" ]; then
  VIOS_BASE_URL=$(docker exec auto-magic-calib-ms-1 printenv VIOS_BASE_URL 2>/dev/null)
fi

# Compose environment file.
if [ -z "$VIOS_BASE_URL" ]; then
  VIOS_BASE_URL=$(grep ^VIOS_BASE_URL "$REPO_ROOT/compose/.env" 2>/dev/null | cut -d= -f2-)
fi

if [ -n "$VIOS_BASE_URL" ]; then
  curl -sf "${VIOS_BASE_URL}/vst/api/v1/sensor/list" >/dev/null \
    && echo "VIOS up at $VIOS_BASE_URL" \
    || { echo "VIOS_BASE_URL=$VIOS_BASE_URL is set but not responding"; VIOS_BASE_URL=""; }
fi
```

If VIOS is not reachable, ask the user to deploy VIOS and provide the base URL. Do not start RTSP capture until `${VIOS_BASE_URL}/vst/api/v1/sensor/list` returns 200.

If VIOS is reachable but the AMC microservice is missing `VIOS_BASE_URL`, set it and relaunch:

```bash
cd "$REPO_ROOT/compose"

# Add or update VIOS_BASE_URL in compose/.env.
grep -q '^VIOS_BASE_URL=' .env \
  && sed -i 's|^VIOS_BASE_URL=.*|VIOS_BASE_URL=http://<VIOS_HOST>:30888|' .env \
  || echo 'VIOS_BASE_URL=http://<VIOS_HOST>:30888' >> .env

docker compose up -d
docker exec auto-magic-calib-ms-1 printenv VIOS_BASE_URL
```

### Step 1 - Create Project

`POST /v1/create_project` with form field `project_name`. Save the returned `project_id`.

### Step 2 - Start RTSP Capture

```
POST /v1/rtsp/capture/<project_id>
Content-Type: application/json

{
  "streams": [
    {"rtsp_url": "rtsp://...", "camera_name": "cam_00", "sensor_id": null},
    {"rtsp_url": "rtsp://...", "camera_name": "cam_01", "sensor_id": null}
  ],
  "duration_seconds": 180,
  "vios_token": null,
  "ssl_verify": false
}
```

The response can nest session fields under `session`:

```
{"code": 0, "message": "...", "session": {"session_id": "...", "status": "STARTING"}}
```

Save `session.session_id`.

### Step 3 - Poll Capture, Then Ingest

Poll every 10 seconds:

```
GET /v1/rtsp/capture/<project_id>/<session_id>
```

Session lifecycle:

```
STARTING -> RECORDING -> COMPLETED -> INGESTING -> INGESTED
                       -> ERROR
RECORDING -> CANCELLED
```

When capture reaches `COMPLETED`, ingest the recorded clips into the AMC project:

```
POST /v1/rtsp/capture/<project_id>/<session_id>/ingest
```

After ingest succeeds, the project has video files attached and the rest of the workflow matches the MP4 upload path.

Need to stop early: `POST /v1/rtsp/capture/<project_id>/<session_id>/stop`. A partial clip can still be ingested if VIOS produced one.

Other session endpoints:

- `GET /v1/rtsp/sessions/<project_id>` - list sessions for a project.
- `DELETE /v1/rtsp/session/<project_id>/<session_id>` - delete a session record.

### Step 4 - Upload Settings, Alignment, Layout, and Optional Files

Resolve local files using the anchor-file pattern above. Upload resolved files:

| File | Endpoint | Notes |
|---|---|---|
| Calibration settings | `POST /v1/config/<project_id>` | JSON body posted as-is; replaces UI Step 3 |
| Alignment JSON | `POST /v1/upload_alignment/<project_id>` | Multipart `alignment_file` |
| Layout PNG | `POST /v1/upload_layout/<project_id>` | Multipart `layout_file` |
| Ground truth zip | `POST /v1/upload_gt_file/<project_id>` | Optional |
| Focal lengths | `POST /v1/upload_focal_length/<project_id>` | Optional repeated `focal_length` values |

If settings are missing, direct the user to UI Step 3: Parameters, then ask which detector to use (`resnet` or `transformer`) before calibration. If alignment or layout is missing, direct the user to UI Step 4: Alignment for this project. For RTSP projects, videos are already ingested; do not re-upload videos in the UI fallback.

Before continuing after UI Step 4, verify:

```bash
PROJECT_ID=<project_id>
REPO_ROOT=$(git rev-parse --show-toplevel)
PROJECT_DIR_REL=$(grep ^PROJECT_DIR "$REPO_ROOT/compose/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
HOST_PROJECTS=$(cd "$REPO_ROOT/compose" && realpath "${PROJECT_DIR_REL:-../../projects}")
ls "$HOST_PROJECTS/project_${PROJECT_ID}/manual_adjustment/"
# Expected: alignment_data.json, layout.png
```

### Step 5 - Verify, Calibrate, Poll, and Fetch Results

Verify:

```
POST /v1/verify_project/<project_id>
```

The project must return `project_state == "READY"`.

Confirm the plan before calibrating. Summarize:

- Stream count and recording duration.
- Detector: `resnet` or `transformer`.
- Settings source: uploaded settings file or UI/defaults.
- Alignment/layout source: uploaded files or UI manual adjustment.
- Optional GT and focal-length overrides.

Start calibration:

```
POST /v1/calibrate/<project_id>
Content-Type: application/json

{"detector_type": "resnet"}
```

Poll:

```
GET /v1/get_project_info/<project_id>
```

Stop on `COMPLETED` or `ERROR`. On error, fetch `GET /v1/amc/calibrate/<project_id>/log`.

Fetch results:

```
GET /v1/result/<project_id>/evaluation_statistics
```

Only expect evaluation statistics when GT was uploaded.

### Step 6 - Optional VGGT Refinement

After AMC calibration completes, read `project_info.vggt_state` from `GET /v1/get_project_info/<project_id>`.

- If `vggt_state == "READY"`, ask whether to run VGGT refinement.
- If confirmed, call `POST /v1/vggt/calibrate/<project_id>`, poll `vggt_state`, then fetch `GET /v1/vggt_results/<project_id>/evaluation_statistics`.
- If VGGT is not ready, skip it and explain that AMC calibration is complete.

## Complete Python Script

Use `scripts/run_rtsp_calibration.py` from the `auto-magic-calib` repo root.

Common environment variables:

```bash
export BASE_URL=http://<HOST_IP>:8000
export PROJECT_NAME=rtsp_calibration_run
export RTSP_URLS='rtsp://user:pass@cam0/stream,rtsp://user:pass@cam1/stream'
export CAMERA_NAMES='cam_00,cam_01'
export DURATION_SECONDS=180
export VIOS_BASE_URL=http://<VIOS_HOST>:30888
export CONFIG_FILE=/path/to/settings.json
export RUN_VGGT=false

python3 skills/amc-run-rtsp-calibration/scripts/run_rtsp_calibration.py
```

Alternative stream input:

```bash
export STREAMS_JSON='[
  {"rtsp_url":"rtsp://cam0/stream","camera_name":"cam_00","sensor_id":null},
  {"rtsp_url":"rtsp://cam1/stream","camera_name":"cam_01","sensor_id":null}
]'
```

Optional env vars are `ALIGNMENT_JSON`, `LAYOUT_PNG`, `GT_ZIP`, `FOCAL_LENGTHS`, `DETECTOR_TYPE`, `VIOS_TOKEN`, `SSL_VERIFY`, `RUN_VGGT`, `REPO_ROOT`, and `PROJECTS_DIR`.

## Success Criteria

- VIOS health probe returns 200.
- Capture session reaches `COMPLETED`.
- Ingest returns success and project info shows the expected video files.
- `verify_project` returns `READY`.
- AMC calibration reaches `project_state == "COMPLETED"`.
- If GT was uploaded, evaluation statistics are returned.
- No RTSP credentials, bearer tokens, NGC keys, or HuggingFace tokens are printed or persisted by the agent.

## Key Output Files

Results persist on the AMC server under:

```
projects/project_<project_id>/
|-- manual_adjustment/
|   |-- alignment_data.json
|   `-- layout.png
|-- output/
|   |-- single_view_results/cam_XX/
|   |   |-- camInfo_hyper_XX.yaml
|   |   `-- trajDump_Stream_0_3d.txt
|   `-- multi_view_results/BA_output/results_ba/
|       |-- initial/camInfo_XX.yaml
|       `-- refined/camInfo_XX.yaml
`-- calibration.log
```

## Troubleshooting

| Issue | Fix |
|---|---|
| VIOS `/vst/api/v1/sensor/list` returns connection refused | VIOS is not running or not reachable from this host. Ask the user to deploy VIOS or provide the reachable base URL. |
| Capture endpoint returns 503 or "VIOS not configured" | Set `VIOS_BASE_URL` in the AMC microservice environment and relaunch `docker compose up -d`. |
| Session stuck in `STARTING` | VIOS accepted the request but sensors may not be online. Check `${VIOS_BASE_URL}/vst/api/v1/sensor/list` and wait 20-30 seconds after sensor restarts. |
| Session stuck in `RECORDING` past `duration_seconds` | Call `POST /v1/rtsp/capture/<project_id>/<session_id>/stop`, then ingest the partial clip if available. |
| Ingest fails with "No clip available" | The recording window may not overlap the VIOS timeline. Wait for sensors to become online, then start a new capture. |
| 400 "empty streams" | Pass at least one stream object with `rtsp_url` and `camera_name`. |
| 400 "duration too short" | Use `duration_seconds >= 60`. |
| 404 on `/v1/rtsp/capture/<project_id>` | Create the project first with `/v1/create_project`. |
| `verify_project` is not `READY` after ingest | Check project info and confirm expected videos, alignment, and layout are attached. |
| Calibration reaches `ERROR` | Fetch `GET /v1/amc/calibrate/<project_id>/log`; common causes are insufficient tracklets, static scenes, or incorrect alignment. |

## Related Skills

- `skills/amc-setup-calibration-stack/SKILL.md` - start AMC microservice and UI first.
- `skills/amc-run-video-calibration/SKILL.md` - calibrate from local pre-recorded MP4 files.
- `skills/amc-run-sample-calibration/SKILL.md` - verify the stack with the bundled sample dataset.

<!-- signing marker -->
