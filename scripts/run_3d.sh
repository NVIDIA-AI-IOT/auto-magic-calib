#!/usr/bin/env bash

# Default values
DETECTOR_TYPE="resnet"
AMC_OUT_DIR_INPUT=""

# Function to display usage
usage() {
    echo "Usage: $0 -o <output_directory> [-d <detector_type>]"
    echo ""
    echo "Required arguments:"
    echo "  -o <dir>     AMC SV calibration output directory"
    echo ""
    echo "Optional arguments:"
    echo "  -d <type>    Detector type: 'resnet' or 'transformer' (default: 'resnet')"
    echo "  -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -o /path/to/output_dir"
    echo "  $0 -o /path/to/output_dir -d transformer"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o)
            AMC_OUT_DIR_INPUT="$2"
            shift 2
            ;;
        -d)
            DETECTOR_TYPE="$2"
            shift 2
            ;;
        -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Check required argument
if [ -z "$AMC_OUT_DIR_INPUT" ]; then
    echo "Error: Missing required argument - output directory (-o)"
    usage
    exit 1
fi

# Validate detector type
if [[ "$DETECTOR_TYPE" != "resnet" && "$DETECTOR_TYPE" != "transformer" ]]; then
    echo "Error: Invalid detector type '$DETECTOR_TYPE'. Must be 'resnet' or 'transformer'"
    exit 1
fi

echo "Using detector type: $DETECTOR_TYPE"

# Function to setup detector config symlink
setup_detector_configs() {
    local config_dir="$(dirname "$0")/../configs/config_DeepStream"
    
    echo "Setting up detector configs for $DETECTOR_TYPE..."
    
    # Remove existing symlink if it exists
    [ -L "$config_dir/conf_3d.txt" ] && rm "$config_dir/conf_3d.txt"
    
    # Create new symlink
    ln -sf "config_deepstream_3d_${DETECTOR_TYPE}.txt" "$config_dir/conf_3d.txt"
    
    echo "Created symlink:"
    echo "  conf_3d.txt -> config_deepstream_3d_${DETECTOR_TYPE}.txt"
}

# Function to cleanup detector config symlink
cleanup_detector_configs() {
    local config_dir="$(dirname "$0")/../configs/config_DeepStream"
    
    # Remove symlink if it exists
    [ -L "$config_dir/conf_3d.txt" ] && rm "$config_dir/conf_3d.txt"
}

# Function to cleanup on exit
cleanup() {
    cleanup_detector_configs
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Setup detector config symlink
setup_detector_configs

cp $AMC_OUT_DIR_INPUT/camInfo_hyper_00.yaml camInfo-temp.yaml

amc_out_dir=$(realpath -m "$AMC_OUT_DIR_INPUT")  # -m allows non-existent paths
echo "AMC SV calibration output directory: ${amc_out_dir}"

# check if output directory exists
if [ ! -d "$amc_out_dir" ]; then
    echo "AMC SV calibration output directory does not exist: ${amc_out_dir}"
    exit 1
fi

SCRIPT_ROOT="$(dirname "$0")"

# edit video file name 
rectified_video_path="${amc_out_dir}/rectified.mp4"
rectified_video=$(echo "${rectified_video_path}" | sed 's/\//\\\//g')
echo "rectified_video: ${rectified_video}"
sed -i "s/uri=file:\/\/video.mp4/uri=file:\/\/${rectified_video}/g" $SCRIPT_ROOT/../configs/config_DeepStream/conf_3d.txt

echo "Running SV3DT with the estimated camera parameters..."
docker run -it --rm --security-opt=no-new-privileges --ipc=host --network host --gpus all \
    -e DISPLAY=$DISPLAY -e P4ROOT=$P4ROOT -v /tmp/.X11-unix/:/tmp/.X11-unix \
    -v $HOME:$HOME -w $PWD --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    --shm-size="8g" -v /tmp/.X11-unix/:/tmp/.X11-unix \
    nvcr.io/nvidia/deepstream:8.0-triton-multiarch \
    deepstream-app -c $SCRIPT_ROOT/../configs/config_DeepStream/conf_3d.txt

# restore video file name
sed -i "s/uri=file:\/\/${rectified_video}/uri=file:\/\/video.mp4/g" $SCRIPT_ROOT/../configs/config_DeepStream/conf_3d.txt
rm camInfo-temp.yaml

#mkdir -p $3
mv peoplenet_3d.mp4 $amc_out_dir
mv trajDump_Stream_0.txt $amc_out_dir/trajDump_Stream_0_3d.txt

echo "Generating a SV3DT video..."

# skip VDT because VDT is not public release yet
## run VDT
## edit root path
#echo "Setting root_path in config_3d.yaml:"
#sed -i "s/root_dummy/${amc_out_dir//\//\\/}/g" $SCRIPT_ROOT/../configs/config_DeepStream/config_3d.yaml
#grep "root_path:" $SCRIPT_ROOT/../configs/config_DeepStream/config_3d.yaml
#
#docker run --gpus all -it --rm --security-opt=no-new-privileges -v $HOME:$HOME -w $PWD \
#    gitlab-master.nvidia.com:5005/deepstreamsdk/release_image/visual-diagnostic-tool:0.3.2 \
#    ds_visual_diagnostic_tool cli -i $SCRIPT_ROOT/../configs/config_DeepStream/config_3d.yaml -o ${amc_out_dir}/SV3DT.avi --overwrite
#
## restore root path
#echo "Restoring root_path in config_3d.yaml:"
#sed -i "s/${amc_out_dir//\//\\/}/root_dummy/g" $SCRIPT_ROOT/../configs/config_DeepStream/config_3d.yaml
#grep "root_path:" $SCRIPT_ROOT/../configs/config_DeepStream/config_3d.yaml
