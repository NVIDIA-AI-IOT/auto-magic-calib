#!/bin/bash

################################################################################
# Copyright (c) 2024, NVIDIA CORPORATION.  All rights reserved.
# NVIDIA Corporation and its licensors retain all intellectual property
# and proprietary rights in and to this software, related documentation
# and any modifications thereto.  Any use, reproduction, disclosure or
# distribution of this software and related documentation without an express
# license agreement from NVIDIA Corporation is strictly prohibited.
################################################################################

setup_auto_magic_calib_container() {
    # Define the source image to make it easier to read and modify
    local source_image="nvcr.io/nvdeepstream/deepstream-tools/auto-magic-calib:0.2"

    # Define the local tag your script needs
    local local_tag="auto-magic-calib:latest"

    echo "Pulling required image: $source_image"
    if docker pull "$source_image"
    then
        echo "Successfully pulled image."

        # Add this line to create the local 'latest' tag
        docker tag "$source_image" "$local_tag"

        echo "Tagged image as '$local_tag' for local use."
    else
        echo "Failed to pull the image. Exiting..."
        exit 1
    fi
}


setup_deepstream_container() {
	if docker pull $DEEPSTREAM_IMAGE
	then
		echo "Pulled DeepStream image"
	else
		echo "Exit..."
		exit 1
	fi
}

# DeepStream container image variable for reuse
DEEPSTREAM_IMAGE="gitlab-master.nvidia.com:5005/deepstreamsdk/release_image/deepstream:8.0.0-triton-25.09.1-ma"


echo "Setup for AutoMagicCalib..."

echo "Pulling required containers..."
setup_deepstream_container;
setup_auto_magic_calib_container;

# DeepStream container doesn't include the detector and Re-ID models needed, so need to download from NGC.
echo "Downloading NGC models..."
NGC_DOWNLOAD='../ngc_download/'
mkdir -p $NGC_DOWNLOAD
MODEL_DIR="../models"
mkdir -p $MODEL_DIR

# Model selection configurable by user: ACC-mode (Transformer) or PERF-mode (ResNet)

# Note: was told we're phasing out from this (etlt, ..). So Re-ID is the only one to be left here?
# Download PeopleNet ResNet34 Detector
DET_ZIP=$NGC_DOWNLOAD/peoplenet_deployable_quantized.zip
wget --content-disposition https://api.ngc.nvidia.com/v2/models/nvidia/tao/peoplenet/versions/deployable_quantized_onnx_v2.6.3/zip -O $DET_ZIP
unzip $DET_ZIP -d $MODEL_DIR
mv $MODEL_DIR/labels.txt $MODEL_DIR/labels_peoplenet_resnet34.txt

# Download Re-ID used by tracker and update Re-ID section in tracker configs
wget 'https://api.ngc.nvidia.com/v2/models/nvidia/tao/reidentificationnet/versions/deployable_v1.2/files/resnet50_market1501_aicity156.onnx' -P $MODEL_DIR

# Download PeopleNet Transformer Detector
curl -L 'https://api.ngc.nvidia.com/v2/models/org/nvidia/team/tao/peoplenet_transformer_v2/deployable_v1.0/files?redirect=true&path=dino_fan_small_astro_delta.onnx' -o $MODEL_DIR/peoplenet_transformer_v2.onnx
wget https://api.ngc.nvidia.com/v2/models/nvidia/tao/peoplenet_transformer/versions/deployable_v1.0/files/labels.txt -O $MODEL_DIR/labels_peoplenet_transformer.txt

# Filter labels to keep only BG and Person, discard Face and Bag
echo "Filtering PeopleNet Transformer labels..."
# Handle different line endings and create filtered version
cat $MODEL_DIR/labels_peoplenet_transformer.txt | tr -d '\r' | sed '/^$/d' | grep -E "^(BG|Person)$" > $MODEL_DIR/labels_peoplenet_transformer_filtered.txt
mv $MODEL_DIR/labels_peoplenet_transformer_filtered.txt $MODEL_DIR/labels_peoplenet_transformer.txt
echo "Labels filtered - kept only BG and Person"


# Update tracker configs for 3D tracking
echo "Updating DeepStream Perception SV3DT configs..."

# Build custom parser for peoplenet transformer model
build_custom_parser() {
	echo "Building custom parser for peoplenet transformer model..."

	# Get the absolute path to the models directory
	MODELS_PATH=$(cd ../models && pwd)

	# Run DeepStream container and build custom parser
	# Note: The models directory is mounted as a volume, so build artifacts will persist on host
	echo "Starting DeepStream container for custom parser build..."

	docker run --rm --privileged --ipc=host --network host --gpus all \
		-e DISPLAY=$DISPLAY -e P4ROOT=$P4ROOT \
		-v /tmp/.X11-unix/:/tmp/.X11-unix \
		-v $HOME:$HOME \
		-v $MODELS_PATH:$MODELS_PATH \
		--cap-add=SYS_PTRACE --security-opt seccomp=unconfined --shm-size="8g" \
		--entrypoint="" \
		$DEEPSTREAM_IMAGE bash -c "
			echo 'Building custom parser inside DeepStream container...'

			# Get CUDA version for compilation from existing environment variable
			export CUDA_VER=\${CUDA_VERSION%%.*}
			echo \"Using CUDA version: \$CUDA_VER (from CUDA_VERSION=\$CUDA_VERSION)\"

			# Navigate to custom parser directory and build
			cd $MODELS_PATH/custom_parser
			echo \"Building in directory: \$(pwd)\"

			echo \"Running make clean...\"
			make clean

			echo \"Running make...\"
			make

			echo \"Custom parser build completed. Generated files:\"
			ls -la *.so 2>/dev/null || echo \"No .so files found\"
		"

	# Verify that build artifacts were created and persisted
	if [ -d "../models/custom_parser" ] && [ "$(ls -A ../models/custom_parser/*.so 2>/dev/null)" ]; then
		echo "✓ Custom parser build artifacts found on host filesystem"

		# Create symlink in config_DeepStream directory
		# CONFIG_DIR="../configs/config_DeepStream"
		# PARSER_SO="../models/custom_parser/libnvds_infercustomparser_tao.so"
		# SYMLINK_PATH="$CONFIG_DIR/libnvds_infercustomparser_tao.so"

		# Remove existing symlink if it exists
		# if [ -L "$SYMLINK_PATH" ]; then
		# 	rm "$SYMLINK_PATH"
		# 	echo "Removed existing symlink"
		# fi

		# Create relative symlink
		# cd "$CONFIG_DIR"
		# ln -s "../../models/custom_parser/libnvds_infercustomparser_tao.so" "libnvds_infercustomparser_tao.so"
		# cd - > /dev/null

		# if [ -L "$SYMLINK_PATH" ]; then
		# 	echo "✓ Created symlink: $SYMLINK_PATH -> ../../models/custom_parser/libnvds_infercustomparser_tao.so"
		# else
		# 	echo "⚠ Warning: Failed to create symlink"
		# fi
	else
		echo "⚠ Warning: Custom parser build artifacts not found - build may have failed"
	fi
}

echo "Building custom parser..."
build_custom_parser

echo "Sample data setup is done"

