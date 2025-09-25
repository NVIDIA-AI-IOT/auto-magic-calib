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
    local source_image="nvcr.io/nvstaging/deepstream/auto-magic-calib:1.0"

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


setup_geocalib_repository() {
    echo "Setting up GeoCalib repository inside auto-magic-calib container..."
    
    # Get the auto-magic-calib container image name
    local auto_magic_image="auto-magic-calib:latest"
    local container_name="auto-magic-calib-geocalib-setup"
    local container_geocalib_temp="/tmp/GeoCalib"
    local container_geocalib_dir="/auto-magic-calib/submodules/GeoCalib"
    
    echo "Cloning GeoCalib repository inside container..."
    
    # Start the container (without --rm so we can commit it)
    docker run -d --name $container_name --privileged --ipc=host --network host \
        --entrypoint="" \
        $auto_magic_image bash -c '
            echo "Setting up GeoCalib repository inside container..."
            
            # Define container variables inside the container
            container_geocalib_temp="/tmp/GeoCalib"
            container_geocalib_dir="/auto-magic-calib/submodules/GeoCalib"
            
            # Install git, wget, tar, and minimal OpenCV runtime deps needed at runtime
            # This keeps Dockerfile unchanged but ensures the committed image contains the libs
            apt update -y && apt install -y git wget tar libgl1 libglib2.0-0 || true
            
            # Create submodules and models directories
            mkdir -p /auto-magic-calib/submodules
            mkdir -p /auto-magic-calib/models
            
            # Clone GeoCalib repository and extract geocalib subdirectory
            if [ ! -d "$container_geocalib_dir/geocalib" ]; then
                echo "Cloning GeoCalib repository..."
                if git clone https://github.com/cvg/GeoCalib.git "$container_geocalib_temp"
                then
                    echo "Successfully cloned GeoCalib repository"
                    echo "Extracting geocalib subdirectory to match original structure..."
                    mkdir -p "$container_geocalib_dir"
                    cp -r "$container_geocalib_temp/geocalib" "$container_geocalib_dir/"
                    rm -rf "$container_geocalib_temp"
                    echo "GeoCalib geocalib subdirectory extracted to $container_geocalib_dir/geocalib"
                else
                    echo "Failed to clone GeoCalib repository from https://github.com/cvg/GeoCalib.git"
                    echo "Please check your internet connection and GitHub repository access"
                    exit 1
                fi
            else
                echo "GeoCalib geocalib already exists at $container_geocalib_dir/geocalib"
            fi
            
            # Download GeoCalib model tar only (no extraction)
            model_dir="/auto-magic-calib/models/geocalib"
            model_url="https://github.com/cvg/GeoCalib/releases/download/v1.0/geocalib-pinhole.tar"
            model_tar="$model_dir/geocalib-pinhole.tar"
            
            mkdir -p "$model_dir"
            if [ ! -f "$model_tar" ]; then
                echo "Downloading GeoCalib model tar to $model_tar..."
                if wget -O "$model_tar" "$model_url"; then
                    echo "✓ GeoCalib model tar downloaded"
                else
                    echo "Failed to download GeoCalib model from $model_url"
                    exit 1
                fi
            else
                echo "GeoCalib model tar already exists at $model_tar"
            fi
            
            echo "GeoCalib setup completed inside container"
            # Keep container running briefly for commit
            sleep 2
        '
    
    # Wait for the setup to complete and capture the container exit code
    echo "Waiting for GeoCalib setup to complete..."
    setup_exit_code=$(docker wait $container_name)
    echo "$setup_exit_code"
    
    # Check if the setup was successful based on the container's exit code
    if [ "$setup_exit_code" -eq 0 ]; then
        echo "✓ GeoCalib repository successfully set up inside container"
        
        # Commit the container with GeoCalib to create updated image
        echo "Committing container with GeoCalib to auto-magic-calib:latest (restoring default CMD)..."
        # Reset ENTRYPOINT and set default CMD to /bin/bash so interactive runs behave as before
        docker commit \
            --change 'ENTRYPOINT []' \
            --change 'CMD ["/bin/bash"]' \
            $container_name $auto_magic_image
        
        if [ $? -eq 0 ]; then
            echo "✓ Successfully committed updated container image with GeoCalib"
        else
            echo "⚠ Warning: Failed to commit container image"
        fi
    else
        echo "⚠ Warning: Failed to set up GeoCalib repository inside container (exit code: $setup_exit_code)"
        echo "Please ensure:"
        echo "  1. Internet connectivity from within the container"
        echo "  2. GitHub access to https://github.com/cvg/GeoCalib"
        echo "  3. The model URL is reachable: https://github.com/cvg/GeoCalib/releases/download/v1.0/geocalib-pinhole.tar"
    fi
    
    # Clean up the temporary container
    echo "Cleaning up temporary container..."
    docker rm $container_name > /dev/null 2>&1
}

echo "Setup for AutoMagicCalib..."

echo "Pulling required containers..."
setup_deepstream_container;
setup_auto_magic_calib_container;

echo "Setting up GeoCalib repository inside container..."
setup_geocalib_repository;

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

