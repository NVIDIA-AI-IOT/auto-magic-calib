echo $1
# Convert to absolute path to avoid relative path issues
target_dir=$(realpath "$1")
chown $(id -u):$(id -g) "$target_dir"
cd "$target_dir"
mkdir kitti_detector/Stream_0
mv kitti_detector/00_000* kitti_detector/Stream_0/.
cd $OLDPWD

SCRIPT_ROOT="$(dirname "$0")"

bash $SCRIPT_ROOT/kittiDetect2mot_4_viz.sh \
    -i "$target_dir/kitti_detector/Stream_0" \
    -o "$target_dir/Det-Stream_0.log"

