---
name: "test-sample-dataset"
description: "Run end-to-end calibration on the shipped sample dataset (assets/sdg_08_2_sample_data_010926.zip) against a running AMC microservice. Use when user says 'test sample dataset', 'run sample calibration', 'verify AMC install', or 'launch and test'."
owner: "nvidia-automagiccalib-team"
service: "auto-magic-calib"
version: "1.0.0"
reviewed: "2026-04-22"
metadata:
  author: "NVIDIA AutoMagicCalib Team"
  tags: [amc, calibration, sample, rest-api, validation, python]
  languages: [python, bash]
  domain: calibration
---

# Skill: Test Sample Dataset

## Purpose

Run a full calibration on the bundled sample dataset (`assets/sdg_08_2_sample_data_010926.zip`, 4 synthetic warehouse cameras with ground truth) against a running AutoMagicCalib microservice. Useful for verifying that a freshly-launched stack works end-to-end before throwing real data at it.

The sample includes GT, so the run produces evaluation metrics (L2 distance, reprojection error) — no calibration parameter tuning needed.

## Prerequisites

- [ ] AMC microservice running (follow `.claude/skills/setup-launch-containers/SKILL.md` if not)
- [ ] `assets/sdg_08_2_sample_data_010926.zip` present in the repo
- [ ] Python 3 with `requests` installed (`pip install requests`) — or use the Swagger UI path below

## Quick Start for Agents

**"launch AMC and test sample dataset" (or similar):**

1. Run `.claude/skills/setup-launch-containers/SKILL.md` first.
2. Wait for `/v1/ready` to return OK.
3. Run the Python script below with `BASE_URL=http://localhost:${MS_PORT}`.
4. Report final metrics + UI URL for manual inspection.

**"test sample dataset" (MS already running):**

1. Detect backend: scan ports 8000–8009 for a `/v1/ready` response.
2. If none → point to the setup skill.
3. Run the Python script.
4. Report metrics.

### Detect Running Backend

```bash
MS_PORT=""
for port in {8000..8009}; do
  if curl -s "http://localhost:$port/v1/ready" | grep -q '"code":0'; then
    MS_PORT=$port; break
  fi
done
[ -z "$MS_PORT" ] && { echo "No running backend. Run setup-launch-containers skill first."; exit 1; }
echo "Backend on port $MS_PORT"
```

### Extract Sample Data (idempotent)

```bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
SAMPLE_ZIP="$REPO_ROOT/assets/sdg_08_2_sample_data_010926.zip"
SAMPLE_DIR="$REPO_ROOT/assets/.cache/sdg_08_2_sample_data_010926"

if [ ! -d "$SAMPLE_DIR" ]; then
  mkdir -p "$SAMPLE_DIR"
  unzip -q "$SAMPLE_ZIP" -d "$SAMPLE_DIR"
fi
ls "$SAMPLE_DIR"
# Expected (possibly inside a wrapper folder): alignment_data/  GT.zip  videos/
```

## Python Script (Primary Path)

Copy into a file (e.g. `run_sample_test.py`) and run with `python3 run_sample_test.py`. Edit `BASE_URL` / `SAMPLE_DIR` at the top if needed.

```python
import os
import sys
import time
from pathlib import Path

import requests

# --- Configuration ---
REPO_ROOT = Path(os.environ.get("REPO_ROOT", Path(__file__).resolve().parent))
MS_PORT = os.environ.get("MS_PORT", "8000")
BASE_URL = os.environ.get("BASE_URL", f"http://localhost:{MS_PORT}/v1")
SAMPLE_DIR = Path(os.environ.get(
    "SAMPLE_DIR",
    REPO_ROOT / "assets" / ".cache" / "sdg_08_2_sample_data_010926",
))

# Locate sample files (handle an optional wrapper folder from unzip)
def _find(path: Path, name: str) -> Path:
    hits = list(path.rglob(name))
    if not hits:
        sys.exit(f"Could not find {name} under {path}")
    return hits[0]

videos = sorted(SAMPLE_DIR.rglob("cam_*.mp4"))
alignment = _find(SAMPLE_DIR, "alignment_data.json")
layout = _find(SAMPLE_DIR, "layout.png")
gt_zip = _find(SAMPLE_DIR, "GT.zip")

assert len(videos) >= 2, f"Need >=2 cam_XX.mp4 under {SAMPLE_DIR}, found {len(videos)}"
print(f"Base URL:   {BASE_URL}")
print(f"Sample dir: {SAMPLE_DIR}")
print(f"Videos:     {[v.name for v in videos]}")

s = requests.Session()

# Step 1 — Create project
project_name = f"sample_test_{int(time.time())}"
r = s.post(f"{BASE_URL}/create_project", data={"project_name": project_name})
r.raise_for_status()
project_id = r.json()["project_id"]
print(f"[1] Created project {project_name} → {project_id}")

# Step 2 — Upload videos (sorted alphabetically; upload order defines camera indices)
files, handles = [], []
for v in videos:
    f = open(v, "rb"); handles.append(f)
    files.append(("files", (v.name, f, "video/mp4")))
r = s.post(f"{BASE_URL}/upload_video_files/{project_id}", files=files, timeout=300)
for f in handles: f.close()
r.raise_for_status()
print(f"[2] Uploaded {len(videos)} videos")

# Step 3 — Upload alignment JSON
with open(alignment, "rb") as f:
    r = s.post(f"{BASE_URL}/upload_alignment/{project_id}",
               files={"alignment_file": (alignment.name, f, "application/json")})
    r.raise_for_status()
print(f"[3] Uploaded alignment JSON")

# Step 4 — Upload layout PNG
with open(layout, "rb") as f:
    r = s.post(f"{BASE_URL}/upload_layout/{project_id}",
               files={"layout_file": (layout.name, f, "image/png")})
    r.raise_for_status()
print(f"[4] Uploaded layout PNG")

# Step 5 — Upload GT zip (enables evaluation metrics)
with open(gt_zip, "rb") as f:
    r = s.post(f"{BASE_URL}/upload_gt_file/{project_id}",
               files={"gt_file": (gt_zip.name, f, "application/zip")}, timeout=120)
    r.raise_for_status()
print(f"[5] Uploaded GT zip")

# Step 6 — Verify project
r = s.post(f"{BASE_URL}/verify_project/{project_id}")
r.raise_for_status()
state = r.json()["project_state"]
print(f"[6] verify_project → {state}")
assert state == "READY", f"Expected READY, got {state}"

# Step 7 — Start calibration (defaults work for this dataset)
r = s.post(f"{BASE_URL}/calibrate/{project_id}", json={"detector_type": "resnet"})
r.raise_for_status()
print(f"[7] Calibration started (detector=resnet)")

# Step 8 — Poll for completion (~10–30 min for sample)
print(f"[8] Polling (expect 10–30 min)...")
start = time.time()
last_state = ""
while time.time() - start < 3600:
    r = s.get(f"{BASE_URL}/get_project_info/{project_id}")
    r.raise_for_status()
    st = r.json()["project_info"]["project_state"]
    elapsed = int(time.time() - start)
    if st != last_state:
        print(f"    [{elapsed:>4}s] {st}", flush=True)
        last_state = st
    if st == "COMPLETED":
        print(f"[8] Completed in {elapsed}s")
        break
    if st == "ERROR":
        sys.exit(f"Calibration failed. Pull log: GET {BASE_URL}/amc/calibrate/{project_id}/log")
    time.sleep(10)
else:
    sys.exit("Timed out after 60 min")

# Step 9 — Evaluation statistics (GT was uploaded, so this should return metrics)
r = s.get(f"{BASE_URL}/result/{project_id}/evaluation_statistics")
if r.status_code == 200:
    stats = r.json().get("statistics", r.json())
    print(f"\n[9] Evaluation statistics:")
    for k, v in stats.items():
        print(f"    {k}: {v}")
else:
    print(f"\n[9] evaluation_statistics returned {r.status_code}: {r.text[:200]}")

print(f"\nProject ID: {project_id}")
print(f"Inspect in UI: open the project in the web UI to view results and overlay videos")
```

### Running the Script

```bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
export MS_PORT=$(grep AUTO_MAGIC_CALIB_MS_PORT "$REPO_ROOT/compose/.env" | cut -d= -f2)
export BASE_URL="http://localhost:${MS_PORT}/v1"

python3 run_sample_test.py
```

## Alternative: Swagger UI Walkthrough

The microservice exposes an interactive OpenAPI UI at **`http://<HOST_IP>:<MS_PORT>/docs`**. If you prefer clicking through the API by hand:

1. Open `http://<HOST_IP>:<MS_PORT>/docs` in a browser.
2. Unzip `assets/sdg_08_2_sample_data_010926.zip` to `assets/.cache/sdg_08_2_sample_data_010926/`.
3. Execute these endpoints **in order**, copying the `project_id` from step 1 into subsequent paths:

   | # | Endpoint | Body / Files |
   |---|---|---|
   | 1 | `POST /v1/create_project` | `project_name`: any string |
   | 2 | `POST /v1/upload_video_files/{project_id}` | `files`: upload all 4 `videos/cam_0*.mp4` **sorted by name** |
   | 3 | `POST /v1/upload_alignment/{project_id}` | `alignment_file`: `alignment_data/alignment_data.json` |
   | 4 | `POST /v1/upload_layout/{project_id}` | `layout_file`: `alignment_data/layout.png` |
   | 5 | `POST /v1/upload_gt_file/{project_id}` | `gt_file`: `GT.zip` |
   | 6 | `POST /v1/verify_project/{project_id}` | — (expect `project_state: READY`) |
   | 7 | `POST /v1/calibrate/{project_id}` | JSON: `{"detector_type": "resnet"}` |
   | 8 | `GET /v1/get_project_info/{project_id}` | Refresh every ~10 s until `project_state` = `COMPLETED` |
   | 9 | `GET /v1/result/{project_id}/evaluation_statistics` | Read L2 distance + reprojection error |

This is the same sequence the Python script runs, just executed manually.

## Success Criteria

- Project reaches `project_state == "COMPLETED"` within ~30 min.
- `/v1/result/{id}/evaluation_statistics` returns non-empty `statistics` (GT was uploaded).
- No `ERROR` state encountered.

Representative metrics for the sample (yours should be similar):

```
Average L2 distance(m)               : < 1.5
Average reprojection error 0(px)     : < 10
```

## Key Output Files (on the server)

Results persist under `$REPO_ROOT/projects/project_<project_id>/`:

```
projects/project_<project_id>/
├── output/
│   ├── single_view_results/cam_XX/
│   │   ├── camInfo_hyper_XX.yaml
│   │   └── trajDump_Stream_0_3d.txt
│   └── multi_view_results/BA_output/results_ba/refined/
│       └── camInfo_XX.yaml          # ← final calibration (use this)
└── calibration.log
```

## Monitoring Progress

```bash
PROJECT_ID=<id_from_step_1>
REPO_ROOT=$(git rev-parse --show-toplevel)
tail -F --retry "$REPO_ROOT/projects/project_${PROJECT_ID}/calibration.log"
```

Or stream MS logs:

```bash
docker compose -f "$REPO_ROOT/compose/compose.yml" logs -f auto-magic-calib-ms
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `requests` not installed | `pip install requests` (ideally inside a venv) |
| `verify_project` returns state `!= READY` | Confirm all 4 videos + alignment + layout + GT uploaded; inspect `GET /v1/get_project_info/{id}` response |
| Sample not extracted | `unzip assets/sdg_08_2_sample_data_010926.zip -d assets/.cache/sdg_08_2_sample_data_010926/` |
| `cam_*.mp4` glob finds 0 files | Check wrapper-folder depth: `find assets/.cache/sdg_08_2_sample_data_010926 -name "cam_*.mp4"` |
| Calibration times out (>60 min) | Check `calibration.log` for "insufficient tracklets"; see root `README.md` guidelines on input videos |
| Upload returns 413 | Raise server upload limit, or split files (sample files are <200 MB total so this is unusual) |
| Port scan finds no backend | Backend not running — run `setup-launch-containers` skill |

## Related Skills

- `.claude/skills/setup-launch-containers/SKILL.md` — launch MS + UI (prerequisite).
- `.claude/skills/calibrate-videos/SKILL.md` — run calibration on your own pre-recorded MP4s.
- `.claude/skills/calibrate-rtsp-streams/SKILL.md` — run calibration on live RTSP streams via VIOS.

Root `README.md` "Sample Data Setup" and "Calibration Workflow (UI)" sections cover the human-oriented path through the same sample.
