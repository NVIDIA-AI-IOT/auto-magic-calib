if [ ! $1 ] 
then
	echo "Usage: bash $0 <output_foler>"
	exit 1
fi

echo $1

SCRIPT_ROOT="$(dirname "$0")"

mkdir $SCRIPT_ROOT/../configs/config_DeepStream/kitti_detector 

echo "Running deepstream app to detect people..."
docker run -it --rm --security-opt=no-new-privileges --ipc=host --network host --gpus all  \
	-e P4ROOT=$P4ROOT -v /tmp/.X11-unix/:/tmp/.X11-unix -v $HOME:$HOME -w $PWD \
	--cap-add=SYS_PTRACE --security-opt seccomp=unconfined --shm-size="8g" \
	-v /tmp/.X11-unix/:/tmp/.X11-unix \
	gitlab-master.nvidia.com:5005/deepstreamsdk/release_image/deepstream:8.0.0-triton-25.09.1-ma \
	deepstream-app -c $SCRIPT_ROOT/../configs/config_DeepStream/conf_2d.txt

mv $SCRIPT_ROOT/../configs/config_DeepStream/kitti_detector $1 -f
mv peoplenet_out_2d.mp4 $1 -f
