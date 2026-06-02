---
name: "amc-run-video-calibration"
description: "Calibrate a new dataset from pre-recorded video files via the AutoMagicCalib REST API. Use when user has local MP4s and says 'calibrate my videos', 'run AMC on these videos', or similar."
owner: "NVIDIA CORPORATION"
service: "auto-magic-calib"
version: "1.0.0"
reviewed: "2026-04-28"
license: "Apache-2.0"
metadata:
  author: "NVIDIA CORPORATION"
  license: "Apache-2.0"
  tags: [amc, calibration, rest-api, camera, python]
---

# Skill: Calibrate from Video Files

## When to Use This Skill

Activate this skill when the user has pre-recorded MP4 files and wants to calibrate them via the AMC REST API. Typical prompts:

- "calibrate my videos" / "run AMC on these videos"
- "calibrate from video files"

Drives calibration through the REST API on user-supplied **pre-recorded MP4 files** — no CLI scripts or Docker bind-mounts required, just a running microservice and your files.

## Prerequisites

- [ ] AMC microservice **and** UI running (follow `skills/amc-setup-calibration-stack/SKILL.md`)
- [ ] You know the microservice URL (e.g. `http://<HOST_IP>:<MS_PORT>`) and UI URL
- [ ] Video files locally as `cam_00.mp4`, `cam_01.mp4`, … time-synchronized, ~1920×1080
- [ ] Python 3 with `requests`

## Data Privacy

Video files uploaded via this skill are transmitted to the AutoMagicCalib backend (REST endpoint). Only use this skill when the backend is deployed on a trusted platform / network.

## What to Ask the User

### Required
(Video-file naming and the microservice URL are specified under Prerequisites above — collect the inputs below.)
1. **Videos directory** — the folder the skill globs for `cam_*.mp4`, uploaded sorted alphabetically.
2. **Microservice URL**
3. **Project name** — short descriptive string

### Auto-Detected (ask only if not found)

Scanned silently in the videos dir and its parent; ask only if missing/ambiguous, else UI fallback:

| File | Candidate filenames | UI fallback |
|---|---|---|
| Calibration settings | `settings.json`, `config.json`, `calibration_config.json` | UI Step 3: Parameters |
| Alignment JSON | `alignment_data.json` | UI Step 4: Alignment |
| Layout PNG | `layout.png` | UI Step 4: Alignment |

Posting the settings file replaces UI Step 3 and may pin the detector (`resnet`/`transformer`), which is passed to `/calibrate` separately — see Step 4.

### Optional
4. **Ground truth zip** — `GT.zip` with `_World_Cameras_Camera_XX/` folders (enables evaluation metrics)
5. **Focal lengths** — one per camera, e.g. `1269.0, 1099.5, 1099.5`
6. **Detector type** — `resnet` (default, fast) or `transformer` (slower, better under occlusion)
7. **Run VGGT refinement?** — only if VGGT model is loaded (see setup skill)

See root `README.md` "Custom Dataset" section for input-video guidelines and ground-truth format.

---

## Instructions

All endpoints below are implemented end-to-end in the [Complete Python Script](#complete-python-script) — the prose is the workflow plus the decisions the agent must make; the script is the authoritative runnable.

### Step 1 — Create Project

`POST /v1/create_project` (form field `project_name`) → save the returned `project_id`.

### Step 2 — Upload Videos (required)

`POST /v1/upload_video_files/<project_id>` (multipart `files`). **Upload sorted alphabetically** — the server assigns camera indices by upload order.

### Step 3 — Resolve Local Files (Auto-Scan, Ask, or UI)

For each of calibration-settings, alignment, and layout, run this resolution:

1. **Auto-scan** `VIDEO_DIR` and `VIDEO_DIR.parent` for the candidate filenames (table above).
2. If **exactly one match**, use it silently and print what was found.
3. If **zero or multiple matches**, ask the user for an explicit path via `AskUserQuestion`. If they don't have the file, mark it for UI fallback.
4. **UI fallback**: tell the user to complete the corresponding UI step; wait for confirmation; for alignment/layout also verify files landed in `projects/project_<id>/manual_adjustment/`.

### Step 4 — Upload Resolved Files

Upload each file resolved locally:

| File | Endpoint | Notes |
|---|---|---|
| Calibration settings | `POST /v1/config/<project_id>` (JSON, posted as-is) | Replaces UI Step 3 (rectification, bundle-adjustment, evaluation, detector, …). Non-2xx is surfaced — never silently fall back. Skip on the UI-fallback path. |
| Alignment | `POST /v1/upload_alignment/<project_id>` (`alignment_data.json`) | |
| Layout | `POST /v1/upload_layout/<project_id>` (`layout.png`) | |
| Ground truth (optional) | `POST /v1/upload_gt_file/<project_id>` (`GT.zip`) | Enables evaluation metrics |
| Focal lengths (optional) | `POST /v1/upload_focal_length/<project_id>` (repeated `focal_length=`) | Overrides GeoCalib estimates |

After a successful settings POST, parse the file for `"detector"` / `"detector_type"` — if it's `"resnet"` or `"transformer"`, use that value for the `/calibrate` call in Step 7 (detector is a separate API parameter, not consumed by `/config`).

### Step 5 — UI Fallback (only for files the user doesn't have locally)

If any of settings / alignment / layout was not resolved in Step 3, direct the user to the appropriate UI step:

- **Settings missing** → "Open UI project `<project_id>`, go to **Step 3: Parameters**, tune via the settings dialog (or accept defaults), click Save." **Also**: before the `/calibrate` call, ask the user via `AskUserQuestion` whether to use the `resnet` or `transformer` detector — UI Step 3 doesn't cover detector choice.
- **Alignment or layout missing** → "Open UI project `<project_id>`, go to **Step 4: Alignment**, upload layout, mark correspondence points, click Save."

Wait for user confirmation. For alignment/layout, verify on disk before continuing:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve PROJECT_DIR from compose/.env (default: projects/ at repo root).
PROJECT_DIR_REL=$(grep ^PROJECT_DIR "$REPO_ROOT/compose/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
HOST_PROJECTS=$(cd "$REPO_ROOT/compose" && realpath "${PROJECT_DIR_REL:-../../projects}")

ls "$HOST_PROJECTS/project_<project_id>/manual_adjustment/"
# Expected: alignment_data.json, layout.png
```

### Step 6 — Verify Project

`POST /v1/verify_project/<project_id>` → must return `{"project_state": "READY"}` before calibrating.

### Step 7 — Start Calibration

**Confirm the plan before calibrating.** Whether the settings file and detector were auto-detected or asked, present a short summary and confirm via `AskUserQuestion` before `POST /calibrate` — the resolved values are the defaults, so confirming is one click, but the user can switch the detector or skip an auto-detected settings file. Summarize:

- **Detector** — `resnet` or `transformer` (the value to be sent).
- **Calibration settings** — the file being applied (path), or "defaults" if none.
- **Optional overrides** — ground-truth zip and focal lengths, if any.

```
POST /v1/calibrate/<project_id>
Content-Type: application/json

{"detector_type": "resnet"}
```

### Step 8 — Poll for Completion

`GET /v1/get_project_info/<project_id>` every 10 s — `project_info.project_state` goes `RUNNING` → `COMPLETED` (or `ERROR`, pull the log). Typical time: **10–60 min** depending on video length and detector.

### Step 9 — Get Results

`GET /v1/result/<project_id>/evaluation_statistics` (only if GT was uploaded; includes `Average L2 distance(m)` and `Average reprojection error 0(px)`), and `GET /v1/amc/calibrate/<project_id>/log` for the calibration log.

### Step 10 — (Optional) VGGT Refinement

Only if `vggt_state == "READY"` (VGGT model staged, see setup skill): `POST /v1/vggt/calibrate/<project_id>`, poll `vggt_state` via `get_project_info`, then `GET /v1/vggt_results/<project_id>/evaluation_statistics`.

---

## Complete Python Script

```python
import os
import time
from pathlib import Path

import requests

# --- Edit these ---
BASE_URL       = "http://<HOST_IP>:<MS_PORT>/v1"
PROJECT_NAME   = "my_calibration_run"
VIDEO_DIR      = Path("/path/to/videos")
# Optional overrides — leave as None to trigger auto-scan -> ask-user -> UI fallback.
CONFIG_FILE    = None   # settings.json — full UI-Step-3 override; if it pins a detector, it's used below
ALIGNMENT_JSON = None   # alignment_data.json
LAYOUT_PNG     = None   # layout.png
GT_ZIP         = None   # optional GT.zip
FOCAL_LENGTHS  = None   # optional, e.g. [1269.0, 1099.5]
DETECTOR_TYPE  = "resnet"   # or "transformer"; overridden if CONFIG_FILE pins one
RUN_VGGT       = False

# Host projects dir (for verifying manual alignment output); override via PROJECTS_DIR env var.
REPO_ROOT    = Path(os.environ.get("REPO_ROOT", Path.cwd()))
PROJECTS_DIR = Path(os.environ.get("PROJECTS_DIR", REPO_ROOT / "projects"))

VIDEO_FILES = sorted(VIDEO_DIR.glob("cam_*.mp4"))
assert VIDEO_FILES, f"No cam_*.mp4 files under {VIDEO_DIR}"

# --- Auto-scan helper ---
def _resolve_local(override, candidate_names, scan_dirs, label):
    """Path if found locally (override or single scan hit), else None (→ ask user / UI fallback)."""
    if override and Path(override).exists():
        return Path(override)
    hits = []
    for d in scan_dirs:
        for name in candidate_names:
            p = d / name
            if p.exists():
                hits.append(p)
    if len(hits) == 1:
        print(f"    auto-detected {label}: {hits[0]}")
        return hits[0]
    if len(hits) > 1:
        print(f"    multiple {label} candidates in {scan_dirs}: {hits} — skipping auto-detect")
    return None

_scan_dirs = [VIDEO_DIR, VIDEO_DIR.parent]
CONFIG_FILE    = _resolve_local(CONFIG_FILE,    ["settings.json", "config.json", "calibration_config.json"], _scan_dirs, "config")
ALIGNMENT_JSON = _resolve_local(ALIGNMENT_JSON, ["alignment_data.json"],                                       _scan_dirs, "alignment")
LAYOUT_PNG     = _resolve_local(LAYOUT_PNG,     ["layout.png"],                                                _scan_dirs, "layout")

s = requests.Session()

# Step 1 — Create project
r = s.post(f"{BASE_URL}/create_project", data={"project_name": PROJECT_NAME})
r.raise_for_status()
project_id = r.json()["project_id"]
print(f"[1] Created project: {project_id}")

# Step 2 — Upload videos (sorted)
files, handles = [], []
for v in VIDEO_FILES:
    f = open(v, "rb"); handles.append(f)
    files.append(("files", (v.name, f, "video/mp4")))
r = s.post(f"{BASE_URL}/upload_video_files/{project_id}", files=files, timeout=300)
for f in handles: f.close()
r.raise_for_status()
print(f"[2] Uploaded {len(VIDEO_FILES)} videos")

# Step 3/4 — Upload resolved files
if CONFIG_FILE and CONFIG_FILE.exists():
    r = s.post(f"{BASE_URL}/config/{project_id}",
               data=CONFIG_FILE.read_bytes(),
               headers={"Content-Type": "application/json"})
    r.raise_for_status()
    print(f"[3] Applied calibration config from {CONFIG_FILE.name} (replaces UI Step 3)")
    # Detector is consumed via the separate /calibrate parameter, so extract it for Step 7.
    try:
        import json as _json
        _cfg = _json.loads(CONFIG_FILE.read_text())
        _det = _cfg.get("detector") or _cfg.get("detector_type")
        if _det in ("resnet", "transformer"):
            DETECTOR_TYPE = _det
            print(f"    Detector overridden from config: {DETECTOR_TYPE}")
    except Exception:
        pass  # non-JSON config or no detector field — keep DETECTOR_TYPE as-is

if ALIGNMENT_JSON and ALIGNMENT_JSON.exists():
    with open(ALIGNMENT_JSON, "rb") as f:
        s.post(f"{BASE_URL}/upload_alignment/{project_id}",
               files={"alignment_file": (ALIGNMENT_JSON.name, f, "application/json")}).raise_for_status()
    print(f"[3] Uploaded alignment: {ALIGNMENT_JSON.name}")

if LAYOUT_PNG and LAYOUT_PNG.exists():
    with open(LAYOUT_PNG, "rb") as f:
        s.post(f"{BASE_URL}/upload_layout/{project_id}",
               files={"layout_file": (LAYOUT_PNG.name, f, "image/png")}).raise_for_status()
    print(f"[3] Uploaded layout: {LAYOUT_PNG.name}")

if GT_ZIP and GT_ZIP.exists():
    with open(GT_ZIP, "rb") as f:
        s.post(f"{BASE_URL}/upload_gt_file/{project_id}",
               files={"gt_file": (GT_ZIP.name, f, "application/zip")}, timeout=120).raise_for_status()
    print(f"[3] Uploaded GT zip")

if FOCAL_LENGTHS:
    s.post(f"{BASE_URL}/upload_focal_length/{project_id}",
           data={"focal_length": FOCAL_LENGTHS}).raise_for_status()
    print(f"[3] Uploaded focal lengths: {FOCAL_LENGTHS}")

# Step 5 — UI fallback for anything not resolved
ui_tasks = []
if not CONFIG_FILE:
    ui_tasks.append("Step 3 (Parameters): tune settings or accept defaults, then Save.")
if not ALIGNMENT_JSON or not LAYOUT_PNG:
    ui_tasks.append("Step 4 (Alignment): upload layout, mark correspondence points, then Save.")
if ui_tasks:
    print(f"\n[5] UI action required for project {project_id}:")
    for t in ui_tasks:
        print(f"    - {t}")
    input("    Press Enter when done...")
    # Verify alignment files if the UI fallback was used for alignment
    if not ALIGNMENT_JSON or not LAYOUT_PNG:
        manual_dir = PROJECTS_DIR / f"project_{project_id}" / "manual_adjustment"
        assert (manual_dir / "alignment_data.json").exists() and (manual_dir / "layout.png").exists(), (
            f"Alignment files missing under {manual_dir}. Re-check UI Step 4 and click Save."
        )
        print(f"    Alignment files verified at {manual_dir}")

# Step 6 — Verify
r = s.post(f"{BASE_URL}/verify_project/{project_id}")
r.raise_for_status()
state = r.json()["project_state"]
print(f"[6] Project state: {state}")
assert state == "READY", f"Expected READY, got {state}"

# Step 7 — Calibrate
s.post(f"{BASE_URL}/calibrate/{project_id}",
       json={"detector_type": DETECTOR_TYPE}).raise_for_status()
print(f"[7] Calibration started (detector={DETECTOR_TYPE})")

# Step 8 — Poll. Print on every state change, plus a heartbeat at least once a
# minute so a long RUNNING state still shows progress.
print(f"[8] Polling (10–60 min typical)...")
start, last_state, last_beat = time.time(), "", 0.0
while time.time() - start < 5400:
    info = s.get(f"{BASE_URL}/get_project_info/{project_id}").json()
    st = info["project_info"]["project_state"]
    mins, secs = divmod(int(time.time() - start), 60)
    if st != last_state or time.time() - last_beat >= 60:
        print(f"    [{mins:>3}m {secs:02d}s] {st}", flush=True)
        last_state, last_beat = st, time.time()
    if st == "COMPLETED":
        print(f"[8] Done in {mins}m {secs:02d}s"); break
    if st == "ERROR":
        # Surface the tail of the calibration log so the failure is actionable.
        try:
            log_lines = s.get(f"{BASE_URL}/amc/calibrate/{project_id}/log").text.splitlines()
            print("    --- last calibration log lines ---")
            for line in log_lines[-20:]:
                print(f"    {line}")
        except Exception:
            pass
        raise RuntimeError(f"ERROR state — full log: GET {BASE_URL}/amc/calibrate/{project_id}/log")
    time.sleep(10)
else:
    raise RuntimeError(
        f"Calibration still running after {int((time.time() - start) // 60)} min — "
        f"inspect GET {BASE_URL}/amc/calibrate/{project_id}/log"
    )

# Step 9 — Results
print(f"\n[9] Results:")
r = s.get(f"{BASE_URL}/result/{project_id}/evaluation_statistics")
if r.status_code == 200:
    for k, v in (r.json().get("statistics") or r.json()).items():
        print(f"    {k}: {v}")
else:
    print("    No GT provided — skipping evaluation_statistics")

# Step 10 — VGGT (optional)
if RUN_VGGT:
    info = s.get(f"{BASE_URL}/get_project_info/{project_id}").json()
    vggt_state = info.get("project_info", {}).get("vggt_state", "INIT")
    if vggt_state == "READY":
        s.post(f"{BASE_URL}/vggt/calibrate/{project_id}").raise_for_status()
        print("\n[10] VGGT started")
        t0 = time.time()
        while time.time() - t0 < 900:
            vs = s.get(f"{BASE_URL}/get_project_info/{project_id}").json() \
                .get("project_info", {}).get("vggt_state", "INIT")
            if vs == "COMPLETED":
                print("     VGGT done"); break
            if vs == "ERROR":
                raise RuntimeError("VGGT failed")
            time.sleep(10)
    else:
        print(f"\n[10] VGGT not ready (state={vggt_state}) — skipping")

print(f"\nProject: {project_id}")
print("Review the calibration:")
print(f"    UI:                open project {project_id} in the AMC web UI, then the Results page to view the overlay")
print(f"    Final camera parameters: projects/project_{project_id}/output/multi_view_results/BA_output/results_ba/refined/camInfo_XX.yaml")
```

## Success Criteria

- `project_state == "COMPLETED"` after polling.
- If manual alignment was used: `projects/project_<id>/manual_adjustment/` contains `alignment_data.json` + `layout.png`.
- If GT was uploaded: evaluation returns typical thresholds:
  - `Average L2 distance(m)` < 1.5
  - `Average reprojection error 0(px)` < 5
- No `ERROR` state.

## Key Output Files (on server)

```
projects/project_<project_id>/
├── manual_adjustment/
│   ├── alignment_data.json
│   └── layout.png
├── output/
│   ├── single_view_results/cam_XX/
│   │   ├── camInfo_hyper_XX.yaml
│   │   └── trajDump_Stream_0_3d.txt
│   └── multi_view_results/BA_output/results_ba/
│       ├── initial/camInfo_XX.yaml
│       └── refined/camInfo_XX.yaml          # ← final calibration
└── calibration.log
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `verify_project` state not `READY` | Confirm videos uploaded and alignment + layout are present (either via API or via UI manual alignment) |
| Manual alignment files missing after UI step | User didn't click Save; also verify `projects/project_<id>/manual_adjustment/` exists |
| Calibration stuck `RUNNING` > 90 min | `GET /v1/amc/calibrate/<id>/log` — usually insufficient tracklets (scene too static). See "Custom Dataset" guidelines in root README. |
| Immediate `ERROR` state | Check video naming: must be `cam_00.mp4`, `cam_01.mp4`, … contiguous |
| Low L2 but high reprojection | Provide explicit `focal_length` override via Step 3 |
| VGGT `INIT`, never `READY` | VGGT model not loaded — see setup skill Step 2 |
| Upload timeout | Large videos — bump `timeout=300` to e.g. `600` in the script |

## For Downstream Skills — MV3DT Export

A downstream Multi-View 3D Tracking skill fetches the MV3DT-format calibration directly from the microservice (this skill does **not** download it; it returns the `project_id`). After this skill reports `COMPLETED`:

- `GET /v1/result/{project_id}/mv3dt_result?result_type=amc` → `mv3dt_output.zip` (contains `transforms.yml`).
- If VGGT ran to `COMPLETED` (Step 10): `?result_type=vggt` → `vggt_mv3dt_output.zip`.

## Related Skills

- `skills/amc-setup-calibration-stack/SKILL.md` — start MS + UI first.
- `skills/amc-run-sample-calibration/SKILL.md` — verify the stack with the bundled sample before trying your own.

Root `README.md` "Custom Dataset" and "Calibration Workflow (UI)" sections document input-video guidelines and the UI-driven alternative to this API flow.
