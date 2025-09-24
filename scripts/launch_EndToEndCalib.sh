#!/usr/bin/env bash

# Error handling function
handle_error() {
    local step_name="$1"
    local error_code="$2"
    echo ""
    echo "================================================================"
    echo "ERROR: $step_name failed with exit code $error_code"
    echo "================================================================"
    echo "The calibration pipeline has encountered an error and cannot continue."
    echo "Please check the error messages above for more details."
    echo ""
    echo "Suggestions:"
    echo "- Verify all input files and directories exist and are accessible"
    echo "- Check that you have sufficient disk space and permissions"
    echo "- Ensure all dependencies are properly installed"
    echo "- Try running the command again"
    echo ""
    echo "If the problem persists, please review the error messages and"
    echo "ensure your input data and configuration are correct."
    echo "================================================================"
    exit $error_code
}

# Sanity check functions
verify_file_exists() {
    local file_path="$1"
    local description="$2"
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: Missing $description: $file_path"
        return 1
    fi
    echo "✓ Found $description: $file_path"
    return 0
}

verify_directory_exists() {
    local dir_path="$1"
    local description="$2"
    if [[ ! -d "$dir_path" ]]; then
        echo "ERROR: Missing $description: $dir_path"
        return 1
    fi
    echo "✓ Found $description: $dir_path"
    return 0
}

verify_file_not_empty() {
    local file_path="$1"
    local description="$2"
    if [[ ! -s "$file_path" ]]; then
        echo "ERROR: $description is empty or doesn't exist: $file_path"
        return 1
    fi
    echo "✓ Verified $description is not empty: $file_path"
    return 0
}

verify_files_in_directory() {
    local dir_path="$1"
    local pattern="$2"
    local description="$3"
    local min_count="${4:-1}"
    
    if [[ ! -d "$dir_path" ]]; then
        echo "ERROR: Directory doesn't exist: $dir_path"
        return 1
    fi
    
    local count=$(find "$dir_path" -name "$pattern" -type f | wc -l)
    if [[ $count -lt $min_count ]]; then
        echo "ERROR: Expected at least $min_count $description in $dir_path, found $count"
        return 1
    fi
    echo "✓ Found $count $description in $dir_path"
    return 0
}

# Pre-process sanity checks
verify_inputs_before_process() {
    local process_name="$1"
    shift
    local files_to_check=("$@")
    
    echo ""
    echo "================================================================"
    echo "PRE-CHECK: Verifying inputs for $process_name"
    echo "================================================================"
    
    local check_failed=0
    for file_desc in "${files_to_check[@]}"; do
        # Split file_desc into type:path:description
        IFS=':' read -r check_type check_path check_desc <<< "$file_desc"
        case "$check_type" in
            "file")
                if ! verify_file_exists "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "dir")
                if ! verify_directory_exists "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "file_nonempty")
                if ! verify_file_not_empty "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "files_in_dir")
                # Format: files_in_dir:dir_path:pattern:description:min_count
                IFS=':' read -r _ dir_path pattern desc min_count <<< "$file_desc"
                if ! verify_files_in_directory "$dir_path" "$pattern" "$desc" "${min_count:-1}"; then
                    check_failed=1
                fi
                ;;
        esac
    done
    
    if [[ $check_failed -eq 1 ]]; then
        echo ""
        echo "❌ PRE-CHECK FAILED: Missing required inputs for $process_name"
        exit 1
    fi
    echo ""
    echo "✅ PRE-CHECK PASSED: All required inputs found for $process_name"
}

# Post-process sanity checks
verify_outputs_after_process() {
    local process_name="$1"
    shift
    local files_to_check=("$@")
    
    echo ""
    echo "================================================================"
    echo "POST-CHECK: Verifying outputs for $process_name"
    echo "================================================================"
    
    local check_failed=0
    for file_desc in "${files_to_check[@]}"; do
        # Split file_desc into type:path:description
        IFS=':' read -r check_type check_path check_desc <<< "$file_desc"
        case "$check_type" in
            "file")
                if ! verify_file_exists "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "dir")
                if ! verify_directory_exists "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "file_nonempty")
                if ! verify_file_not_empty "$check_path" "$check_desc"; then
                    check_failed=1
                fi
                ;;
            "files_in_dir")
                # Format: files_in_dir:dir_path:pattern:description:min_count
                IFS=':' read -r _ dir_path pattern desc min_count <<< "$file_desc"
                if ! verify_files_in_directory "$dir_path" "$pattern" "$desc" "${min_count:-1}"; then
                    check_failed=1
                fi
                ;;
        esac
    done
    
    if [[ $check_failed -eq 1 ]]; then
        echo ""
        echo "❌ POST-CHECK FAILED: Missing expected outputs for $process_name"
        exit 1
    fi
    echo ""
    echo "✅ POST-CHECK PASSED: All expected outputs found for $process_name"
}

# Set up error trapping for the entire script
set -e
trap 'handle_error "Calibration Pipeline" $?' ERR

# Default values
MODE="docker"
NO_PLOT=""
VIDEO_DIR=""
OUTPUT_BASE_DIR=""
LAYOUT_IMAGE_PATH=""
DETECTOR_TYPE=""
GROUNDTRUTH_DIR=""
FOCAL_LENGTH_OVERRIDES=""

# Function to display usage
usage() {
    echo "Usage: $0 -v <video_dir> -o <output_base_dir> [-g <groundtruth_dir> -l <layout_image_path>] [-d <detector_type>] [-m <mode>] [--no-plot] [-f <focal_lengths>]"
    echo ""
    echo "This script runs the complete calibration pipeline:"
    echo "1. Single-view calibration for all videos in the video directory"
    echo "2. Multi-view calibration using the single-view results"
    echo "3. Bundle adjustment"
    echo "4. Evaluation (if ground truth directory is provided)"
    echo ""
    echo "Required arguments:"
    echo "  -v <video_dir>        Directory containing input video files (*.mp4)"
    echo "  -o <output_base_dir>  Base directory for all outputs"
    echo ""
    echo "Optional arguments:"
    echo "  -g <groundtruth_dir>  Ground truth directory for evaluation (optional)"
    echo "  -l <layout_image_path> Path to layout image file for manual alignment (optional)"
    echo "  -d <detector_type>    Detector type: 'resnet' or 'transformer' (default: 'resnet')"
    echo "  -m <mode>             Execution mode: 'local' or 'docker' (default: 'docker')"
    echo "  -f <focal_lengths>    Ground truth focal lengths comma-separated (overrides GeoCalib estimates)"
    echo "  --no-plot            Disable plotting for bundle adjustment"
    echo "  -h                    Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Scenario 1: GT + layout map (full calibration pipeline with evaluation and visualization)"
    echo "  $0 -v /home/user/videos/ -o /home/user/output/ -g /home/user/groundtruth/ -l /home/user/data/layout.png"
    echo ""
    echo "  # Scenario 2: Basic pipeline only (calibration only)"
    echo "  $0 -v /home/user/videos/ -o /home/user/output/"
    echo ""
    echo "  # Additional options examples:"
    echo "  $0 -v /home/user/videos/ -o /home/user/output/ -d transformer -m local"
    echo "  $0 -v /home/user/videos/ -o /home/user/output/ -d resnet --no-plot"
    echo "  $0 -v /home/user/videos/ -o /home/user/output/ -f 1200.0,1250.0,1180.0,1220.0"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m)
            MODE="$2"
            shift 2
            ;;
        -v)
            VIDEO_DIR="$2"
            shift 2
            ;;
        -o)
            OUTPUT_BASE_DIR="$2"
            shift 2
            ;;
        -l)
            LAYOUT_IMAGE_PATH="$2"
            shift 2
            ;;
        -d)
            DETECTOR_TYPE="$2"
            shift 2
            ;;
        -g)
            GROUNDTRUTH_DIR="$2"
            shift 2
            ;;
        -f)
            FOCAL_LENGTH_OVERRIDES="$2"
            shift 2
            ;;
        --no-plot)
            NO_PLOT="--no-plot"
            shift
            ;;
        -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate mode
if [[ "$MODE" != "local" && "$MODE" != "docker" ]]; then
    echo "Error: Invalid mode '$MODE'. Must be 'local' or 'docker'"
    exit 1
fi

# Validate required arguments
if [[ -z "$VIDEO_DIR" ]]; then
    echo "Error: Video directory (-v) is required"
    usage
    exit 1
fi

if [[ -z "$OUTPUT_BASE_DIR" ]]; then
    echo "Error: Output base directory (-o) is required"
    usage
    exit 1
fi

# Layout image and ground truth are now independent
# No validation needed here - we'll handle scenarios in the main logic

# Validate video directory exists
if [[ ! -d "$VIDEO_DIR" ]]; then
    echo "Error: Video directory does not exist: $VIDEO_DIR"
    exit 1
fi

# Check layout image exists (only when provided for evaluation)
if [[ -n "$LAYOUT_IMAGE_PATH" && ! -f "$LAYOUT_IMAGE_PATH" ]]; then
    echo "Error: Layout image does not exist: $LAYOUT_IMAGE_PATH"
    exit 1
fi

# Validate ground truth directory exists (if provided)
if [[ -n "$GROUNDTRUTH_DIR" && ! -d "$GROUNDTRUTH_DIR" ]]; then
    echo "Error: Ground truth directory does not exist: $GROUNDTRUTH_DIR"
    exit 1
fi

echo "Running Complete Calibration Pipeline in $MODE mode..."
echo "Video directory: $VIDEO_DIR"
echo "Output base directory: $OUTPUT_BASE_DIR"
echo "Layout image path: ${LAYOUT_IMAGE_PATH:-not provided}"
echo "Ground truth directory: ${GROUNDTRUTH_DIR:-not provided}"
echo "Detector type: ${DETECTOR_TYPE:-transformer}"
echo "No-plot mode: ${NO_PLOT:-disabled}"
if [[ -n "$FOCAL_LENGTH_OVERRIDES" ]]; then
    echo "Focal length overrides: $FOCAL_LENGTH_OVERRIDES (GeoCalib estimates will be replaced)"
fi

# Create output directory
mkdir -p "$OUTPUT_BASE_DIR"

# Initial sanity check for script dependencies and inputs
echo ""
echo "================================================================"
echo "INITIAL VALIDATION: Checking pipeline prerequisites"
echo "================================================================"

initial_checks=(
    "dir:$VIDEO_DIR:video input directory"
    "dir:$OUTPUT_BASE_DIR:output base directory"
)

# Add optional checks if parameters are provided
if [[ -n "$LAYOUT_IMAGE_PATH" ]]; then
    initial_checks+=("file:$LAYOUT_IMAGE_PATH:layout image file")
fi

if [[ -n "$GROUNDTRUTH_DIR" ]]; then
    initial_checks+=("dir:$GROUNDTRUTH_DIR:ground truth directory")
fi

verify_inputs_before_process "Pipeline Prerequisites" "${initial_checks[@]}"

# Setup script directory
SCRIPT_DIR="$(dirname "$0")"

# Verify required scripts exist
script_checks=(
    "file:$SCRIPT_DIR/launch_AutoMagicCalib.sh:AutoMagicCalib launch script"
    "file:$SCRIPT_DIR/run_3d.sh:3D tracking script"
    "file:$SCRIPT_DIR/launch_MultiViewCalib.sh:Multi-view calibration script"
)

if [[ -n "$GROUNDTRUTH_DIR" ]]; then
    script_checks+=("file:$SCRIPT_DIR/launch_Evaluation.sh:evaluation script")
fi

verify_inputs_before_process "Required Scripts" "${script_checks[@]}"

# Read camera configuration from mv_amc_config.yaml
echo "Reading camera configuration from mv_amc_config.yaml..."
CONFIG_FILE="$SCRIPT_DIR/../configs/config_AutoMagicCalib/mv_amc_config.yaml"

# Extract cam_dir from config using Python
CAMERA_CONFIG=$(python3 << EOF
import yaml
import sys

try:
    # Load config file directly using yaml
    with open("$CONFIG_FILE", 'r') as f:
        cfg = yaml.safe_load(f)
    
    cam_dirs = cfg.get('cam_dir', [])
    
    # Format as bash-compatible strings
    cam_dirs_str = " ".join([f"'{d}'" for d in cam_dirs])
    
    print(f"CAM_DIRS_STR='{cam_dirs_str}'")
    print(f"NUM_CAMERAS={len(cam_dirs)}")
    
except Exception as e:
    print(f"Error reading config: {e}", file=sys.stderr)
    sys.exit(1)
EOF
)

if [ $? -ne 0 ]; then
    echo "Error: Failed to read camera configuration from $CONFIG_FILE"
    exit 1
fi

# Parse the output
eval "$CAMERA_CONFIG"

# Convert strings back to arrays
CAM_DIRS=($CAM_DIRS_STR)

echo "Configuration loaded:"
echo "  Camera directories: $CAM_DIRS"
echo "  Number of cameras: $NUM_CAMERAS"

# Parse and validate focal length overrides if provided
FOCAL_LENGTH_ARRAY=()
if [[ -n "$FOCAL_LENGTH_OVERRIDES" ]]; then
    echo ""
    echo "Processing focal length overrides..."
    
    # Split comma-separated focal lengths
    IFS=',' read -ra FOCAL_LENGTH_ARRAY <<< "$FOCAL_LENGTH_OVERRIDES"
    
    # Validate count matches number of cameras
    if [[ ${#FOCAL_LENGTH_ARRAY[@]} -ne $NUM_CAMERAS ]]; then
        echo "Error: Number of focal lengths (${#FOCAL_LENGTH_ARRAY[@]}) does not match number of cameras ($NUM_CAMERAS)"
        echo "Provided focal lengths: ${FOCAL_LENGTH_ARRAY[*]}"
        echo "Expected cameras: ${CAM_DIRS[*]}"
        exit 1
    fi
    
    # Validate and clean each focal length value
    for i in "${!FOCAL_LENGTH_ARRAY[@]}"; do
        focal_length="${FOCAL_LENGTH_ARRAY[$i]}"
        # Trim whitespace
        focal_length=$(echo "$focal_length" | xargs)
        FOCAL_LENGTH_ARRAY[$i]="$focal_length"
        
        # Validate it's a positive number
        if ! [[ "$focal_length" =~ ^[0-9]+\.?[0-9]*$ ]] || (( $(echo "$focal_length <= 0" | bc -l) )); then
            echo "Error: Invalid focal length '$focal_length' for camera ${CAM_DIRS[$i]}. Must be a positive number."
            exit 1
        fi
        
        # Validate reasonable range
        if (( $(echo "$focal_length < 100" | bc -l) )) || (( $(echo "$focal_length > 5000" | bc -l) )); then
            echo "Warning: Focal length $focal_length for camera ${CAM_DIRS[$i]} seems unusual (expected range: 100-5000 pixels)"
        fi
        
        echo "  ${CAM_DIRS[$i]}: $focal_length px"
    done
    
    echo "Focal length overrides will replace GeoCalib estimates while preserving rotation intelligence"
fi

# Find and validate video files for configured cameras
VIDEO_FILES=()
MISSING_CAMERAS=()

for cam_dir in "${CAM_DIRS[@]}"; do
    # Extract camera number from cam_dir (e.g., cam_00 -> 00)
    if [[ $cam_dir =~ cam_([0-9]+) ]]; then
        cam_num="${BASH_REMATCH[1]}"
        # Look for video file with this camera number
        video_file=$(find "$VIDEO_DIR" -name "*${cam_num}*.mp4" -type f | head -1)
        if [[ -n "$video_file" ]]; then
            VIDEO_FILES+=("$video_file")
            echo "  Found video for $cam_dir: $(basename "$video_file")"
        else
            MISSING_CAMERAS+=("$cam_dir")
            echo "  Warning: No video file found for $cam_dir"
        fi
    else
        echo "Error: Invalid camera directory format: $cam_dir"
        exit 1
    fi
done

if [[ ${#MISSING_CAMERAS[@]} -gt 0 ]]; then
    echo "Error: Missing video files for cameras: ${MISSING_CAMERAS[*]}"
    echo "Please ensure all cameras listed in $CONFIG_FILE have corresponding video files in $VIDEO_DIR"
    exit 1
fi

# Setup paths
SV_OUTPUT_DIR="$OUTPUT_BASE_DIR/single_view_results"
MV_OUTPUT_DIR="$OUTPUT_BASE_DIR/multi_view_results"

# Configure based on mode
if [ "$MODE" = "local" ]; then
    AUTO_MAGIC_ROOT="$(dirname "$0")/.."
    ALGO_ROOT="$AUTO_MAGIC_ROOT/core"
    CONFIG_ROOT="$AUTO_MAGIC_ROOT/configs/"
    LAYOUT_SCRIPT_ROOT="$ALGO_ROOT/camera_estimation/"
    PYTHON_CMD="python"
    EXEC_PREFIX=""
    echo "Using local environment..."
elif [ "$MODE" = "docker" ]; then
    AUTO_MAGIC_ROOT="/auto-magic-calib"
    ALGO_ROOT="/auto-magic-calib/core"
    CONFIG_ROOT="/auto-magic-calib/configs"
    LAYOUT_SCRIPT_ROOT="$SCRIPT_DIR"
    EXEC_PREFIX=""  # Will be set when container is started
    echo "Using docker environment..."
fi

# Create single view output directory
mkdir -p "$SV_OUTPUT_DIR"

echo ""
echo "================================================================"
echo "Step 1: Single-view calibration for $NUM_CAMERAS cameras"
echo "================================================================"

# Run single-view calibration for each configured camera
for ((i=0; i<$NUM_CAMERAS; i++)); do
   video_file="${VIDEO_FILES[$i]}"
   # Get camera directory name from config
   cam_dir="${CAM_DIRS[$i]}"
   cam_output_dir="$SV_OUTPUT_DIR/$cam_dir"
   
   echo ""
   echo "Processing $cam_dir: $(basename "$video_file")"
   echo "Output directory: $cam_output_dir"
   
   # Pre-check for AutoMagicCalib inputs
   verify_inputs_before_process "AutoMagicCalib for $cam_dir" \
       "file:$video_file:input video file" \
       "file:$CONFIG_FILE:camera configuration file"
   
   # Temporarily disable global error trap for individual camera processing
   set +e
   
   # Build AutoMagicCalib command
   auto_magic_cmd=("bash" "$SCRIPT_DIR/launch_AutoMagicCalib.sh" "-i" "$video_file" "-o" "$cam_output_dir" "-m" "$MODE")
   
   # Add detector type if specified
   if [[ -n "$DETECTOR_TYPE" ]]; then
       auto_magic_cmd+=("-d" "$DETECTOR_TYPE")
   fi
   
   # Add focal length override if provided
   if [[ -n "$FOCAL_LENGTH_OVERRIDES" ]]; then
       focal_length_for_camera="${FOCAL_LENGTH_ARRAY[$i]}"
       auto_magic_cmd+=("-f" "$focal_length_for_camera")
       echo "  Using focal length override: $focal_length_for_camera px"
   fi
   
   # Run AutoMagicCalib with all parameters
   "${auto_magic_cmd[@]}"
   
   if [ $? -ne 0 ]; then
       handle_error "Single-view calibration for camera $cam_dir" 1
   fi
   
   # Post-check for AutoMagicCalib outputs
   verify_outputs_after_process "AutoMagicCalib for $cam_dir" \
       "dir:$cam_output_dir:camera output directory" \
       "file:$cam_output_dir/rectified.mp4:rectified video" \
       "file:$cam_output_dir/rectified.jpg:rectified image" \
       "file:$cam_output_dir/config_sv_amc.yaml:single-view config file" \
       "file:$cam_output_dir/Det-bboxes.log:detection bounding boxes" \
       "file:$cam_output_dir/Det_bbox_sampling_v2.txt:sampled bounding boxes" \
       "file:$cam_output_dir/camInfo_hyper_00.yaml:camera info file" \
       "file:$cam_output_dir/camInfo_hyper_00_opencv.yaml:OpenCV camera info file"
   
   # Pre-check for 3D tracking inputs
   verify_inputs_before_process "3D tracking for $cam_dir" \
       "file:$cam_output_dir/rectified.mp4:rectified video" \
       "file:$cam_output_dir/camInfo_hyper_00.yaml:camera info file"
   
   # Run 3D tracking pipeline
   echo "Running 3D tracking for $cam_dir..."
   if [[ -n "$DETECTOR_TYPE" ]]; then
       bash "$SCRIPT_DIR/run_3d.sh" -d "$DETECTOR_TYPE" -o "$cam_output_dir"
   else
       bash "$SCRIPT_DIR/run_3d.sh" -o "$cam_output_dir"
   fi
   
   if [ $? -ne 0 ]; then
       handle_error "3D tracking for camera $cam_dir" 1
   fi
   
   # Post-check for 3D tracking outputs
   verify_outputs_after_process "3D tracking for $cam_dir" \
       "file:$cam_output_dir/trajDump_Stream_0_3d.txt:3D trajectory dump file" \
       "file:$cam_output_dir/peoplenet_3d.mp4:3D detection video" \
       "file:$cam_output_dir/rectified.mp4:rectified video"
   
   # Re-enable global error trap
   set -e
done

echo ""
echo "================================================================"
echo "Step 2: Multi-view calibration and bundle adjustment"
echo "================================================================"

# Create multi-view output directory
mkdir -p "$MV_OUTPUT_DIR"

# Pre-check for multi-view calibration inputs
echo ""
echo "Checking single-view calibration outputs before multi-view processing..."
mv_input_checks=()
for cam_dir in "${CAM_DIRS[@]}"; do
   cam_sv_output="$SV_OUTPUT_DIR/$cam_dir"
   mv_input_checks+=(
       "dir:$cam_sv_output:single-view output for $cam_dir"
       "file:$cam_sv_output/trajDump_Stream_0_3d.txt:3D trajectory dump for $cam_dir"
       "file:$cam_sv_output/camInfo_hyper_00_opencv.yaml:OpenCV camera info for $cam_dir"
   )
done

verify_inputs_before_process "Multi-view calibration" \
   "file:$CONFIG_FILE:camera configuration file" \
   "dir:$SV_OUTPUT_DIR:single-view results directory" \
   "${mv_input_checks[@]}"

# Run multi-view calibration using the original config (no modification needed)
set +e
bash "$SCRIPT_DIR/launch_MultiViewCalib.sh" \
   -i "$SV_OUTPUT_DIR" \
   -o "$MV_OUTPUT_DIR" \
   -m "$MODE" \
   $NO_PLOT

if [ $? -ne 0 ]; then
   handle_error "Multi-view calibration and bundle adjustment" 1
fi
set -e

# Post-check for multi-view calibration outputs
verify_outputs_after_process "Multi-view calibration and bundle adjustment" \
    "dir:$MV_OUTPUT_DIR:multi-view output directory" \
    "dir:$MV_OUTPUT_DIR/BA_output/results_ba/refined:bundle adjustment result"

echo ""
echo "================================================================"
echo "Calibration Pipeline Complete!"
echo "================================================================"
echo "Single-view results: $SV_OUTPUT_DIR"
echo "Multi-view results: $MV_OUTPUT_DIR"

# Handle the 4 different scenarios based on GT and layout availability
echo ""
echo "================================================================"
echo "Determining scenario based on provided arguments..."
echo "================================================================"

# Determine scenario
if [[ -n "$GROUNDTRUTH_DIR" && -n "$LAYOUT_IMAGE_PATH" ]]; then
    echo "Scenario 1: Ground truth AND layout map provided"
    echo "Pipeline: SV → MV → Manual Alignment → Evaluation"
    RUN_ALIGNMENT=true
    RUN_EVALUATION=true
elif [[ -n "$GROUNDTRUTH_DIR" && -z "$LAYOUT_IMAGE_PATH" ]]; then
    echo "Scenario 2: Ground truth provided, but no layout map"
    echo "Pipeline: SV → MV (alignment and evaluation require layout map)"
    RUN_ALIGNMENT=false
    RUN_EVALUATION=false
    echo "Note: To run evaluation later, provide layout map and run manual alignment first"
else
    echo "Scenario 3: No ground truth and no layout map"
    echo "Pipeline: SV → MV"
    RUN_ALIGNMENT=false
    RUN_EVALUATION=false
fi

# echo ""

# Step 3: Manual alignment (if layout map is provided)
if [[ "$RUN_ALIGNMENT" = true ]]; then
    echo "================================================================"
    echo "Step 3: Layout alignment"
    echo "================================================================"
    
    # Pre-check for layout alignment inputs
    verify_inputs_before_process "Layout alignment" \
        "file:$CONFIG_FILE:camera configuration file" \
        "dir:$SV_OUTPUT_DIR:single-view results directory" \
        "dir:$MV_OUTPUT_DIR:multi-view results directory" \
        "file:$LAYOUT_IMAGE_PATH:layout image file"
    
    # Setup manual adjustment directory
    MANUAL_ADJUSTMENT_SOURCE="$(dirname "$LAYOUT_IMAGE_PATH")"
    if [[ -d "$MANUAL_ADJUSTMENT_SOURCE" ]]; then
        echo "Creating manual adjustment directory: $MV_OUTPUT_DIR/manual_adjustment -> $MANUAL_ADJUSTMENT_SOURCE"
        cp -r "$MANUAL_ADJUSTMENT_SOURCE" "$MV_OUTPUT_DIR/manual_adjustment"
    else
        echo "Warning: Manual adjustment directory not found at $MANUAL_ADJUSTMENT_SOURCE"
    fi

    # Run layout alignment step (handles existing alignment_data.json internally)
    echo "Running layout alignment (will skip UI if alignment_data.json exists)..."
    ALIGNMENT_DATA_FILE="$MV_OUTPUT_DIR/manual_adjustment/alignment_data.json"
    TRANSFORM_FILE="$MV_OUTPUT_DIR/manual_adjustment/transform_cam0_to_map.json"
    
    set +e
    if [ "$MODE" = "local" ]; then
        python3 "${AUTO_MAGIC_ROOT}/core/camera_estimation/layout_alignment.py" \
            -c "$CONFIG_FILE" \
            -i "$SV_OUTPUT_DIR" \
            -o "$MV_OUTPUT_DIR" \
            -l "$LAYOUT_IMAGE_PATH"
    elif [ "$MODE" = "docker" ]; then
        # Build docker run command with required directory mounts
        LAYOUT_DIR="$(dirname "$LAYOUT_IMAGE_PATH")"
        DOCKER_VOLUMES="-v $PWD/../configs:/auto-magic-calib/configs -v $SV_OUTPUT_DIR:/auto-magic-calib/sv_results -v $MV_OUTPUT_DIR:/auto-magic-calib/mv_results -v $OUTPUT_BASE_DIR:/auto-magic-calib/output -v $LAYOUT_DIR:/auto-magic-calib/layout"
        X11_OPTION="-e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix"
        CALIB_IMAGE="auto-magic-calib"

        # Allow the container (root user) to connect to the host X server
        if command -v xhost >/dev/null 2>&1; then
            echo "Authorizing X access for local root user..."
            xhost +si:localuser:root >/dev/null 2>&1 || xhost +local: >/dev/null 2>&1 || true
        fi

        DOCKER_CONFIG_FILE="/auto-magic-calib/configs/config_AutoMagicCalib/mv_amc_config.yaml"
        DOCKER_SV_RESULTS="/auto-magic-calib/sv_results"
        DOCKER_MV_OUTPUT_DIR="/auto-magic-calib/mv_results"
        DOCKER_LAYOUT_PATH="/auto-magic-calib/layout/$(basename "$LAYOUT_IMAGE_PATH")"

        echo "Executing (docker run): pyarmor_python /auto-magic-calib/core/camera_estimation/layout_alignment.py -c $DOCKER_CONFIG_FILE -i $DOCKER_SV_RESULTS -o $DOCKER_MV_OUTPUT_DIR -l $DOCKER_LAYOUT_PATH"
        docker run --rm -it $X11_OPTION $DOCKER_VOLUMES $CALIB_IMAGE \
            pyarmor_python /auto-magic-calib/core/camera_estimation/layout_alignment.py \
                -c "$DOCKER_CONFIG_FILE" \
                -i "$DOCKER_SV_RESULTS" \
                -o "$DOCKER_MV_OUTPUT_DIR" \
                -l "$DOCKER_LAYOUT_PATH"

        # Revoke X access after UI step completes
        if command -v xhost >/dev/null 2>&1; then
            echo "Revoking X access from local root user..."
            xhost -si:localuser:root >/dev/null 2>&1 || true
        fi
    fi

    if [ $? -ne 0 ]; then
        handle_error "Layout alignment (Step 3)" 1
    fi
    set -e
    
    # Post-check for layout alignment outputs
    verify_outputs_after_process "Layout alignment" \
        "file:$ALIGNMENT_DATA_FILE:alignment data file" \
        "file:$TRANSFORM_FILE:transform cam0 to map file" \
        "dir:$MV_OUTPUT_DIR/manual_adjustment:manual adjustment directory"
    
    echo "Manual alignment complete!"
else
    echo "================================================================"
    echo "Step 3: Manual alignment skipped"
    echo "================================================================"
    echo "Layout map not provided. Manual alignment step skipped."
    if [[ -n "$GROUNDTRUTH_DIR" ]]; then
        echo ""
        echo "To run evaluation with ground truth later:"
        echo "1. Provide layout map and run manual alignment:"
        echo "   python3 ${LAYOUT_SCRIPT_ROOT}/layout_alignment.py -c \"$CONFIG_FILE\" -i \"$SV_OUTPUT_DIR\" -o \"$MV_OUTPUT_DIR\" -l <layout_image_path>"
        echo "2. Then run evaluation:"
        echo "   bash $SCRIPT_DIR/launch_Evaluation.sh -i \"$SV_OUTPUT_DIR\" -o \"$MV_OUTPUT_DIR\" -g \"$GROUNDTRUTH_DIR\" -l <layout_image_path> -m \"$MODE\" $NO_PLOT"
    else
        echo ""
        echo "To run manual alignment later (if needed):"
        echo "python3 ${LAYOUT_SCRIPT_ROOT}/layout_alignment.py -c \"$CONFIG_FILE\" -i \"$SV_OUTPUT_DIR\" -o \"$MV_OUTPUT_DIR\" -l <layout_image_path>"
    fi
fi

# Step 4: Evaluation (if both ground truth and alignment are available)
if [[ "$RUN_EVALUATION" = true ]]; then
    echo ""
    echo "================================================================"
    echo "Step 4: Running evaluation with ground truth data"
    echo "================================================================"
    
    # Ensure alignment was completed successfully
    ALIGNMENT_DATA_FILE="$MV_OUTPUT_DIR/manual_adjustment/alignment_data.json"
    
    # Pre-check for evaluation inputs
    verify_inputs_before_process "Evaluation" \
        "dir:$SV_OUTPUT_DIR:single-view results directory" \
        "dir:$MV_OUTPUT_DIR:multi-view results directory" \
        "dir:$GROUNDTRUTH_DIR:ground truth directory" \
        "file:$LAYOUT_IMAGE_PATH:layout image file" \
        "file:$ALIGNMENT_DATA_FILE:alignment data file"
    
    set +e
    bash "$SCRIPT_DIR/launch_Evaluation.sh" \
        -i "$SV_OUTPUT_DIR" \
        -o "$MV_OUTPUT_DIR" \
        -g "$GROUNDTRUTH_DIR" \
        -l "$LAYOUT_IMAGE_PATH" \
        -m "$MODE" \
        $NO_PLOT
    
    if [ $? -ne 0 ]; then
        handle_error "Evaluation with ground truth data (Step 4)" 1
    fi
    set -e
    
    # Post-check for evaluation outputs
    verify_outputs_after_process "Evaluation" \
        "dir:$MV_OUTPUT_DIR/evaluation:evaluation results directory"
    
    echo "Evaluation complete!"
else
    echo ""
    echo "================================================================"
    echo "Step 4: Evaluation skipped"
    echo "================================================================"
    if [[ -z "$GROUNDTRUTH_DIR" ]]; then
        echo "Ground truth directory not provided. Skipping evaluation."
    elif [[ -z "$LAYOUT_IMAGE_PATH" ]]; then
        echo "Layout map not provided. Cannot run evaluation without manual alignment."
        echo ""
        echo "To run evaluation with ground truth later:"
        echo "1. Provide layout map and run manual alignment:"
        echo "   python3 ${LAYOUT_SCRIPT_ROOT}/layout_alignment.py -c \"$CONFIG_FILE\" -i \"$SV_OUTPUT_DIR\" -o \"$MV_OUTPUT_DIR\" -l <layout_image_path>"
        echo "2. Then run evaluation:"
        echo "   bash $SCRIPT_DIR/launch_Evaluation.sh -i \"$SV_OUTPUT_DIR\" -o \"$MV_OUTPUT_DIR\" -g \"$GROUNDTRUTH_DIR\" -l <layout_image_path> -m \"$MODE\" $NO_PLOT"
    fi
fi

# # Clean up manual adjustment symlink
# if [[ -L "$MV_OUTPUT_DIR/manual_adjustment" ]]; then
#     echo "Cleaning up symlink: $MV_OUTPUT_DIR/manual_adjustment"
#     rm -f "$MV_OUTPUT_DIR/manual_adjustment"
# fi
