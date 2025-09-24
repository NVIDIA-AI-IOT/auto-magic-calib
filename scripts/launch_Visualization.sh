#!/usr/bin/env bash

# Default values
MODE="docker"
SV_RESULTS_DIR=""
OUTPUT_BASE_DIR=""
LAYOUT_IMAGE_PATH=""

# Function to display usage
usage() {
    echo "Usage: $0 -i <sv_results_dir> -o <output_base_dir> -l <layout_image_path> [-m <mode>]"
    echo ""
    echo "This script runs the visualization pipeline:"
    echo "1. Layout alignment (if alignment_data.json does not exist)"
    echo "2. Overlay visualization using calibration results"
    echo ""
    echo "Required arguments:"
    echo "  -i <sv_results_dir>   Directory containing single-view calibration results"
    echo "  -o <output_base_dir>  Base directory for all outputs"
    echo "  -l <layout_image_path> Path to layout image file"
    echo ""
    echo "Optional arguments:"
    echo "  -m <mode>             Execution mode: 'local' or 'docker' (default: 'docker')"
    echo "  -h                    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -i /home/user/single_view_results/ -o /home/user/output/ -l /home/user/data/layout.png"
    echo "  $0 -i /home/user/single_view_results/ -o /home/user/output/ -l /home/user/data/layout.png -m local"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m)
            MODE="$2"
            shift 2
            ;;
        -i)
            SV_RESULTS_DIR="$2"
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
if [[ -z "$SV_RESULTS_DIR" ]]; then
    echo "Error: Single-view results directory (-i) is required"
    usage
    exit 1
fi

if [[ -z "$OUTPUT_BASE_DIR" ]]; then
    echo "Error: Output base directory (-o) is required"
    usage
    exit 1
fi

if [[ -z "$LAYOUT_IMAGE_PATH" ]]; then
    echo "Error: Layout image path (-l) is required"
    usage
    exit 1
fi

# Validate single-view results directory exists
if [[ ! -d "$SV_RESULTS_DIR" ]]; then
    echo "Error: Single-view results directory does not exist: $SV_RESULTS_DIR"
    exit 1
fi

# Check layout image exists
if [[ ! -f "$LAYOUT_IMAGE_PATH" ]]; then
    echo "Error: Layout image does not exist: $LAYOUT_IMAGE_PATH"
    exit 1
fi

echo "Running Visualization Pipeline in $MODE mode..."
echo "Single-view results directory: $SV_RESULTS_DIR"
echo "Output base directory: $OUTPUT_BASE_DIR"
echo "Layout image path: $LAYOUT_IMAGE_PATH"

# Create output directory
mkdir -p "$OUTPUT_BASE_DIR"

# Setup script directory
SCRIPT_DIR="$(dirname "$0")"
CONFIG_FILE="$SCRIPT_DIR/../configs/config_AutoMagicCalib/mv_amc_config.yaml"

# Setup paths
MV_OUTPUT_DIR="$OUTPUT_BASE_DIR/multi_view_results"

# Configure based on mode
if [ "$MODE" = "local" ]; then
    AUTO_MAGIC_ROOT="$(dirname "$0")/.."
    ALGO_ROOT="$AUTO_MAGIC_ROOT/core"
    LAYOUT_SCRIPT_ROOT="$ALGO_ROOT/camera_estimation/"
    PYTHON_CMD="python3"
    EXEC_PREFIX=""
    echo "Using local environment..."
elif [ "$MODE" = "docker" ]; then
    AUTO_MAGIC_ROOT="/auto-magic-calib"
    ALGO_ROOT="/auto-magic-calib/core"
    LAYOUT_SCRIPT_ROOT="$ALGO_ROOT/camera_estimation/"
    CALIB_IMAGE="auto-magic-calib"
    CONTAINER_NAME="visualization_$(date +%s)"
    EXEC_PREFIX="docker exec $CONTAINER_NAME"
    echo "Using docker environment..."
fi

# Create multi-view output directory
mkdir -p "$MV_OUTPUT_DIR"

# Start Docker container if in docker mode
if [ "$MODE" = "docker" ]; then
    echo "================================================================"
    echo "Step 0: Starting Docker container"
    echo "================================================================"
    
    # Build docker run command with required directory mounts
    LAYOUT_DIR="$(dirname "$LAYOUT_IMAGE_PATH")"
    DOCKER_VOLUMES="-v $PWD/../configs:/auto-magic-calib/configs -v $SV_RESULTS_DIR:/auto-magic-calib/sv_results -v $OUTPUT_BASE_DIR:/auto-magic-calib/output -v $LAYOUT_DIR:/auto-magic-calib/layout -v $MV_OUTPUT_DIR:/auto-magic-calib/mv_results "
    X11_OPTION="-e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix"
    
    # Allow the container (root user) to connect to the host X server
    if command -v xhost >/dev/null 2>&1; then
        echo "Authorizing X access for local root user..."
        xhost +si:localuser:root >/dev/null 2>&1 || xhost +local: >/dev/null 2>&1 || true
    fi

    docker run -itd --rm --security-opt=no-new-privileges --name $CONTAINER_NAME $X11_OPTION $DOCKER_VOLUMES $CALIB_IMAGE tail -f /dev/null
    docker ps -a
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to start Docker container"
        exit 1
    fi
    
    echo "Docker container $CONTAINER_NAME started successfully"

    # X11/Qt runtime libraries are baked into the Docker image (see Dockerfile.release)
fi

# Function to cleanup (for Docker mode)
cleanup() {
    if [ "$MODE" = "docker" ] && [ -n "$CONTAINER_NAME" ]; then
        echo "Cleaning up containers..."
        docker stop $CONTAINER_NAME >/dev/null 2>&1
        docker rm $CONTAINER_NAME >/dev/null 2>&1
        echo "Containers stopped successfully"

        # Revoke X access in case the script exits early
        if command -v xhost >/dev/null 2>&1; then
            echo "Revoking X access from local root user (cleanup)..."
            xhost -si:localuser:root >/dev/null 2>&1 || true
        fi
    fi
}

# Set up trap for cleanup on exit
trap cleanup EXIT

echo ""
echo "================================================================"
echo "Step 1: Layout alignment"
echo "================================================================"

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

if [ "$MODE" = "local" ]; then
    python3 "${LAYOUT_SCRIPT_ROOT}/layout_alignment.py" \
        -c "$CONFIG_FILE" \
        -i "$SV_RESULTS_DIR" \
        -o "$MV_OUTPUT_DIR" \
        -l "$LAYOUT_IMAGE_PATH"
elif [ "$MODE" = "docker" ]; then
    DOCKER_CONFIG_FILE="/auto-magic-calib/configs/config_AutoMagicCalib/mv_amc_config.yaml"
    DOCKER_SV_RESULTS="/auto-magic-calib/sv_results"
    DOCKER_OUTPUT_BASE="/auto-magic-calib/output"
    DOCKER_MV_OUTPUT_DIR="/auto-magic-calib/mv_results"
    DOCKER_LAYOUT_PATH="/auto-magic-calib/layout/$(basename "$LAYOUT_IMAGE_PATH")"

    echo "Executing: $EXEC_PREFIX pyarmor_python ${LAYOUT_SCRIPT_ROOT}/layout_alignment.py -c $DOCKER_CONFIG_FILE -i $DOCKER_SV_RESULTS -o $DOCKER_MV_OUTPUT_DIR -l $DOCKER_LAYOUT_PATH"
    $EXEC_PREFIX pyarmor_python "${LAYOUT_SCRIPT_ROOT}/layout_alignment.py" \
        -c "$DOCKER_CONFIG_FILE" \
        -i "$DOCKER_SV_RESULTS" \
        -o "$DOCKER_MV_OUTPUT_DIR" \
        -l "$DOCKER_LAYOUT_PATH"
fi

if [ $? -ne 0 ]; then
    echo "Error: Layout alignment failed"
    exit 1
fi

echo ""
echo "================================================================"
echo "Step 2: Overlay visualization"
echo "================================================================"

# Run overlay visualization
if [ "$MODE" = "local" ]; then
    echo "Executing: python3 ${LAYOUT_SCRIPT_ROOT}/overlay_visualization.py -c $CONFIG_FILE -i $SV_RESULTS_DIR -o $OUTPUT_BASE_DIR -l $LAYOUT_IMAGE_PATH"
    python3 "${LAYOUT_SCRIPT_ROOT}/overlay_visualization.py" \
        -c "$CONFIG_FILE" \
        -i "$SV_RESULTS_DIR" \
        -o "$OUTPUT_BASE_DIR" \
        -l "$LAYOUT_IMAGE_PATH"
elif [ "$MODE" = "docker" ]; then
    # Update paths for docker container
    DOCKER_CONFIG_FILE="/auto-magic-calib/configs/config_AutoMagicCalib/mv_amc_config.yaml"
    DOCKER_SV_RESULTS="/auto-magic-calib/sv_results"
    DOCKER_OUTPUT_BASE="/auto-magic-calib/output"
    DOCKER_LAYOUT_PATH="/auto-magic-calib/layout/$(basename "$LAYOUT_IMAGE_PATH")"
    
    echo "Executing: $EXEC_PREFIX pyarmor_python ${LAYOUT_SCRIPT_ROOT}/overlay_visualization.py -c $DOCKER_CONFIG_FILE -i $DOCKER_SV_RESULTS -o $DOCKER_OUTPUT_BASE -l $DOCKER_LAYOUT_PATH"
    $EXEC_PREFIX pyarmor_python "${LAYOUT_SCRIPT_ROOT}/overlay_visualization.py" \
        -c "$DOCKER_CONFIG_FILE" \
        -i "$DOCKER_SV_RESULTS" \
        -o "$DOCKER_OUTPUT_BASE" \
        -l "$DOCKER_LAYOUT_PATH"
fi

if [ $? -ne 0 ]; then
    echo "Error: Overlay visualization failed"
    exit 1
fi

echo ""
echo "================================================================"
echo "Visualization Pipeline Complete!"
echo "================================================================"
echo "Single-view results: $SV_RESULTS_DIR"
echo "Output directory: $OUTPUT_BASE_DIR"
echo ""
