---
name: "calibrate-new-dataset"
description: "Calibrate a new camera rig (user-supplied videos) via the AutoMagicCalib REST API. Use when the user wants to calibrate their own videos, says 'calibrate new dataset', 'run AMC on my videos', 'calibrate my cameras', or similar. Requires a running AMC microservice."
metadata:
  author: "NVIDIA AutoMagicCalib Team"
  tags: [amc, calibration, rest-api, camera, python]
  languages: [bash, python]
  domain: calibration
service: "auto-magic-calib"
version: "1.0.0"
---

# Skill: Calibrate New Dataset

## Purpose

Run AutoMagicCalib on a **new, user-supplied** dataset by uploading files and driving calibration through the microservice REST API. No CLI scripts or Docker bind-mounts required — just a running microservice and your files.

## Prerequisites

- [ ] AMC microservice **and** UI running (follow `.claude/skills/setup-launch-containers/SKILL.md`)
- [ ] You know the microservice URL (e.g. `http://<HOST_IP>:<MS_PORT>`) and UI URL
- [ ] Video files available locally, named `cam_00.mp4`, `cam_01.mp4`, … (time-synchronized, 1920×1080 recommended)
- [ ] Python 3 with `requests` installed

## What to Ask the User

### Required
1. **Video files** — paths to `cam_00.mp4`, `cam_01.mp4`, … (sorted alphabetically; upload order sets camera indices)
2. **Microservice URL** — e.g. `http://192.168.1.100:8000`
3. **Project name** — short descriptive string
4. **Alignment JSON** — `alignment_data.json` mapping camera views to BEV coordinates
5. **Layout PNG** — bird's-eye-view map image of the scene

   > **If the user doesn't have alignment JSON + layout PNG**: they must complete the alignment step interactively in the UI. See **Step 4: Manual Alignment** below.

### Optional
6. **Ground truth zip** — `GT.zip` with `_World_Cameras_Camera_XX/` folders (enables evaluation metrics)
7. **Focal lengths** — one per camera, e.g. `1269.0, 1099.5, 1099.5`
8. **Detector type** — `resnet` (default, fast) or `transformer` (slower, better under occlusion)
9. **Run VGGT refinement?** — only if VGGT model is loaded (see setup skill)

See root `README.md` "Custom Dataset" section for input-video guidelines and ground-truth format.

---

## API Call Sequence

### Step 1 — Create Project

```
POST /v1/create_project
Content-Type: application/x-www-form-urlencoded

project_name=<your_project_name>
```

Response: `{"project_id": "<id>", ...}` — save `project_id`.

### Step 2 — Upload Videos (required)

```
POST /v1/upload_video_files/<project_id>
Content-Type: multipart/form-data

files: [("files", ("cam_00.mp4", <bytes>, "video/mp4")),
        ("files", ("cam_01.mp4", <bytes>, "video/mp4")), ...]
```

> **Important**: upload sorted alphabetically — the server assigns camera indices by upload order.

### Step 3 — Upload Additional Files

Alignment JSON (required, or do Step 4 manually):
```
POST /v1/upload_alignment/<project_id>
alignment_file: ("alignment_data.json", <bytes>, "application/json")
```

Layout PNG (required, or do Step 4 manually):
```
POST /v1/upload_layout/<project_id>
layout_file: ("layout.png", <bytes>, "image/png")
```

Ground truth (optional, enables evaluation):
```
POST /v1/upload_gt_file/<project_id>
gt_file: ("GT.zip", <bytes>, "application/zip")
```

Focal lengths (optional, overrides GeoCalib estimates):
```
POST /v1/upload_focal_length/<project_id>
focal_length=1269.0&focal_length=1099.5&...
```

### Step 4 — Manual Alignment (only if the user did **not** upload alignment JSON + layout PNG)

1. **Tell the user**: "Open the UI at `http://<HOST_IP>:<UI_PORT>`, navigate to your project `<project_id>`."
2. **Instruct them**: go to **Step 4: Alignment** in the UI stepper, upload a layout image, click corresponding points between camera views and the BEV map, then **Save**.
3. **Wait** for the user to confirm completion.
4. **Verify** the files landed on disk:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve PROJECT_DIR from compose/.env (default: projects/ at repo root)
PROJECT_DIR_REL=$(grep ^PROJECT_DIR "$REPO_ROOT/compose/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
HOST_PROJECTS=$(cd "$REPO_ROOT/compose" && realpath "${PROJECT_DIR_REL:-../../projects}")

ls "$HOST_PROJECTS/project_<project_id>/manual_adjustment/"
# Expected:
#   alignment_data.json
#   layout.png
```

If either is missing, have the user re-check the UI step and confirm they clicked **Save**.

### Step 5 — (Optional) Apply Non-default Configuration

```
GET /v1/config/defaults
POST /v1/config/<project_id>
Content-Type: application/json

{ ...defaults..., "detector_type": "transformer" }
```

Skip to use defaults.

### Step 6 — Verify Project

```
POST /v1/verify_project/<project_id>
```

Response: `{"project_state": "READY"}` — must be `READY` before calibrating.

### Step 7 — Start Calibration

```
POST /v1/calibrate/<project_id>
Content-Type: application/json

{"detector_type": "resnet"}
```

### Step 8 — Poll for Completion

```
GET /v1/get_project_info/<project_id>
```

Poll every 10 s. `project_info.project_state`:

| State | Meaning |
|---|---|
| `RUNNING` | Calibration in progress |
| `COMPLETED` | Finished |
| `ERROR` | Failed — check log |

Typical time: **10–60 min** depending on video length and detector.

### Step 9 — Get Results

```
GET /v1/get_project_info/<project_id>                     # project state
GET /v1/result/<project_id>/evaluation_statistics         # only if GT was uploaded
GET /v1/amc/calibrate/<project_id>/log                    # calibration log
```

Evaluation response includes `Average L2 distance(m)` and `Average reprojection error 0(px)`.

### Step 10 — (Optional) VGGT Refinement

Only if `vggt_state == "READY"` in project info (VGGT model must be loaded, see setup skill):

```
POST /v1/vggt/calibrate/<project_id>
GET  /v1/get_project_info/<project_id>                    # poll vggt_state
GET  /v1/vggt_results/<project_id>/evaluation_statistics  # VGGT metrics
```

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
ALIGNMENT_JSON = Path("/path/to/alignment_data.json")  # or None → manual alignment via UI
LAYOUT_PNG     = Path("/path/to/layout.png")           # or None → manual alignment via UI
GT_ZIP         = None                                   # optional: Path("/path/to/GT.zip")
FOCAL_LENGTHS  = None                                   # optional: [1269.0, 1099.5]
DETECTOR_TYPE  = "resnet"                               # "resnet" or "transformer"
RUN_VGGT       = False

# Projects dir on the host (for verifying manual alignment output).
# Defaults to $REPO_ROOT/projects; override via PROJECTS_DIR env var if compose/.env uses a non-default PROJECT_DIR.
REPO_ROOT    = Path(os.environ.get("REPO_ROOT", Path.cwd()))
PROJECTS_DIR = Path(os.environ.get("PROJECTS_DIR", REPO_ROOT / "projects"))

VIDEO_FILES = sorted(VIDEO_DIR.glob("cam_*.mp4"))
assert VIDEO_FILES, f"No cam_*.mp4 files under {VIDEO_DIR}"

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

# Step 3 — Optional uploads
if ALIGNMENT_JSON and ALIGNMENT_JSON.exists():
    with open(ALIGNMENT_JSON, "rb") as f:
        s.post(f"{BASE_URL}/upload_alignment/{project_id}",
               files={"alignment_file": (ALIGNMENT_JSON.name, f, "application/json")}).raise_for_status()
    print("[3] Uploaded alignment JSON")

if LAYOUT_PNG and LAYOUT_PNG.exists():
    with open(LAYOUT_PNG, "rb") as f:
        s.post(f"{BASE_URL}/upload_layout/{project_id}",
               files={"layout_file": (LAYOUT_PNG.name, f, "image/png")}).raise_for_status()
    print("[3] Uploaded layout PNG")

if GT_ZIP and GT_ZIP.exists():
    with open(GT_ZIP, "rb") as f:
        s.post(f"{BASE_URL}/upload_gt_file/{project_id}",
               files={"gt_file": (GT_ZIP.name, f, "application/zip")}, timeout=120).raise_for_status()
    print("[3] Uploaded GT zip")

if FOCAL_LENGTHS:
    s.post(f"{BASE_URL}/upload_focal_length/{project_id}",
           data={"focal_length": FOCAL_LENGTHS}).raise_for_status()
    print(f"[3] Uploaded focal lengths: {FOCAL_LENGTHS}")

# Step 4 — Manual alignment fallback
needs_manual = not ((ALIGNMENT_JSON and ALIGNMENT_JSON.exists()) and (LAYOUT_PNG and LAYOUT_PNG.exists()))
if needs_manual:
    manual_dir = PROJECTS_DIR / f"project_{project_id}" / "manual_adjustment"
    print(f"\n[4] MANUAL ALIGNMENT REQUIRED")
    print(f"    Open UI and navigate to project {project_id}")
    print(f"    Go to Step 4: Alignment, mark correspondence points, click Save.")
    input("    Press Enter when done...")
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

# Step 8 — Poll
print(f"[8] Polling (10–60 min)...")
start = time.time(); last = ""
while time.time() - start < 3600:
    info = s.get(f"{BASE_URL}/get_project_info/{project_id}").json()
    st = info["project_info"]["project_state"]
    elapsed = int(time.time() - start)
    if st != last:
        print(f"    [{elapsed:>4}s] {st}", flush=True); last = st
    if st == "COMPLETED":
        print(f"[8] Done in {elapsed}s"); break
    if st == "ERROR":
        raise RuntimeError(f"ERROR state — see log: GET {BASE_URL}/amc/calibrate/{project_id}/log")
    time.sleep(10)

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
print(f"Final camera parameters: projects/project_{project_id}/output/multi_view_results/BA_output/results_ba/refined/camInfo_XX.yaml")
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

## Related Skills

- `.claude/skills/setup-launch-containers/SKILL.md` — start MS + UI first.
- `.claude/skills/test-sample-dataset/SKILL.md` — verify the stack with the bundled sample before trying your own.

Root `README.md` "Custom Dataset" and "Calibration Workflow (UI)" sections document input-video guidelines and the UI-driven alternative to this API flow.
