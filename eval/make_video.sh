#!/usr/bin/env bash
# make_video.sh — turn an M2Mapping output run into MP4 videos.
#
# All artifacts land under <run_dir>/video/. Nothing is written to the
# rosbag folder unless you explicitly opt in (see --mode path).
#
# Usage:
#   make_video.sh <run_dir> [--mode MODE] [--fps 30] [--crf 18]
#                          [--skip 50] [--n-out-poses 500]
#                          [--data-dir DIR]
#
# Modes:
#   train        stitch existing train/color/renders/*.png   -> video/train.mp4
#   test         stitch test/color/{gt,renders} side-by-side -> video/test_sbs.mp4
#   all          (default) train+test renders interleaved by filename order;
#                this is the full chronological flythrough of every bag frame
#                                                          -> video/all.mp4
#   all_sbs      same, but each frame is GT|render side-by-side
#                                                          -> video/all_sbs.mp4
#   path         interpolate smooth flythrough poses, write into <run_dir>;
#                prints the symlink command needed for the renderer
#   flythrough   stitch path/color/renders/*.png            -> video/flythrough.mp4

set -euo pipefail

if [[ $# -lt 1 ]]; then
    cat <<EOF >&2
usage: $0 <run_dir> [--mode train|test|all|all_sbs|path|flythrough]
                    [--fps 30] [--crf 18] [--skip 50] [--n-out-poses 500]
                    [--data-dir DIR]
EOF
    exit 1
fi

RUN="$(realpath "$1")"; shift
MODE="all"
FPS=30
CRF=18
SKIP=50
N_OUT=500
DATA_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="$2"; shift 2;;
        --fps)         FPS="$2"; shift 2;;
        --crf)         CRF="$2"; shift 2;;
        --skip)        SKIP="$2"; shift 2;;
        --n-out-poses) N_OUT="$2"; shift 2;;
        --data-dir)    DATA_DIR="$2"; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -d "$RUN" ]] || { echo "run dir not found: $RUN" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not installed; apt-get install -y ffmpeg" >&2; exit 1; }

EVAL_DIR="$(dirname "$(realpath "$0")")"
VIDEO_DIR="$RUN/video"
mkdir -p "$VIDEO_DIR"

# Stitch a list of PNG paths (read from stdin, one per line, in desired order)
# into the given mp4. Caller is responsible for ordering.
stitch_list() {
    local out="$1"
    local list
    list="$(mktemp)"
    awk '{print "file '\''" $0 "'\''"}' > "$list"
    local count
    count=$(wc -l < "$list")
    [[ $count -gt 0 ]] || { echo "no frames provided" >&2; rm -f "$list"; exit 1; }
    echo "stitching $count frames @ ${FPS} fps -> $out"
    ffmpeg -y -loglevel warning \
        -r "$FPS" -f concat -safe 0 -i "$list" \
        -c:v libx264 -pix_fmt yuv420p -crf "$CRF" "$out"
    rm -f "$list"
    echo "done: $out"
}

# Stitch every PNG in a directory, sorted by version-aware filename order.
stitch_dir() {
    local src="$1" out="$2"
    [[ -d "$src" ]] || { echo "missing: $src" >&2; exit 1; }
    find "$src" -maxdepth 1 -name '*.png' | sort -V | stitch_list "$out"
}

# Stitch two parallel image lists side-by-side in a single ffmpeg call.
# Args: <gt_list_file> <render_list_file> <out_mp4>
# The list files are already-formatted concat demuxer manifests.
stitch_two_lists() {
    local gt_list="$1" rd_list="$2" out="$3"
    local n
    n=$(grep -c '^file ' "$gt_list")
    [[ $n -gt 0 ]] || { echo "empty gt list" >&2; exit 1; }
    echo "stitching $n side-by-side frames @ ${FPS} fps -> $out"
    ffmpeg -y -loglevel warning \
        -r "$FPS" -f concat -safe 0 -i "$gt_list" \
        -r "$FPS" -f concat -safe 0 -i "$rd_list" \
        -filter_complex "[0:v][1:v]hstack=inputs=2[v]" -map "[v]" \
        -c:v libx264 -pix_fmt yuv420p -crf "$CRF" "$out"
    echo "done: $out"
}

# Build paired (gt, render) concat lists for a {train,test}/color directory.
make_pair_lists() {
    local color_dir="$1" gt_list="$2" rd_list="$3"
    : > "$gt_list"; : > "$rd_list"
    while IFS= read -r rd; do
        local name="$(basename "$rd")"
        local gt="$color_dir/gt/$name"
        [[ -f "$gt" ]] || continue
        printf "file '%s'\n" "$gt" >> "$gt_list"
        printf "file '%s'\n" "$rd" >> "$rd_list"
    done < <(find "$color_dir/renders" -maxdepth 1 -name '*.png' | sort -V)
}

# Paired lists across both train+test in chronological order.
make_all_pair_lists() {
    local gt_list="$1" rd_list="$2"
    : > "$gt_list"; : > "$rd_list"
    list_all_renders | while IFS= read -r rd; do
        local name="$(basename "$rd")"
        local color_dir="$(dirname "$(dirname "$rd")")"
        local gt="$color_dir/gt/$name"
        [[ -f "$gt" ]] || continue
        printf "file '%s'\n" "$gt" >> "$gt_list"
        printf "file '%s'\n" "$rd" >> "$rd_list"
    done
}

# Combined chronological list of train+test renders. M2Mapping uses LLFF
# split (every 8th frame is test) and the same bag-message-index naming for
# both, so a numeric sort over the union recovers the original time order.
list_all_renders() {
    {
        find "$RUN/train/color/renders" -maxdepth 1 -name '*.png' 2>/dev/null
        find "$RUN/test/color/renders"  -maxdepth 1 -name '*.png' 2>/dev/null
    } | awk -F/ '{print $NF "\t" $0}' | sort -V -k1,1 | cut -f2-
}

case "$MODE" in
    train)
        stitch_dir "$RUN/train/color/renders" "$VIDEO_DIR/train.mp4"
        ;;
    test)
        gt_list="$(mktemp)"; rd_list="$(mktemp)"
        make_pair_lists "$RUN/test/color" "$gt_list" "$rd_list"
        stitch_two_lists "$gt_list" "$rd_list" "$VIDEO_DIR/test_sbs.mp4"
        rm -f "$gt_list" "$rd_list"
        ;;
    all)
        list_all_renders | stitch_list "$VIDEO_DIR/all.mp4"
        ;;
    all_sbs)
        gt_list="$(mktemp)"; rd_list="$(mktemp)"
        make_all_pair_lists "$gt_list" "$rd_list"
        stitch_two_lists "$gt_list" "$rd_list" "$VIDEO_DIR/all_sbs.mp4"
        rm -f "$gt_list" "$rd_list"
        ;;
    path)
        if [[ -z "$DATA_DIR" ]]; then
            echo "ERROR: --mode path requires --data-dir <dir containing color_poses.txt>" >&2
            exit 1
        fi
        [[ -f "$DATA_DIR/color_poses.txt" ]] || {
            echo "ERROR: $DATA_DIR/color_poses.txt not found." >&2
            echo "       Run training once so the parser caches color_poses.txt next to the bag." >&2
            exit 1
        }

        OUT_POSES="$RUN/inter_color_poses.txt"
        echo "generating $N_OUT interpolated poses (skip=$SKIP) -> $OUT_POSES"
        python3 "$EVAL_DIR/inter_poses.py" \
            --data_dir "$DATA_DIR" \
            --key_poses skip --skip "$SKIP" \
            --n_out_poses "$N_OUT" \
            --output_file "$OUT_POSES"

        cat <<EOF

pose file written to: $OUT_POSES

The C++ renderer hard-codes \`<bag_dir>/inter_color_poses.txt\` as the read
location, so to render the flythrough you must symlink (or copy) it:

    ln -sf "$OUT_POSES" "$DATA_DIR/inter_color_poses.txt"

then render:
    cd /root/catkin_ws && source devel/setup.bash
    rosrun neural_mapping neural_mapping_node view "$RUN"

afterwards, clean up the bag dir:
    rm "$DATA_DIR/inter_color_poses.txt"

finally, stitch:
    bash "$0" "$RUN" --mode flythrough --fps $FPS

EOF
        ;;
    flythrough)
        stitch_dir "$RUN/path/color/renders" "$VIDEO_DIR/flythrough.mp4"
        ;;
    *)
        echo "unknown mode: $MODE" >&2; exit 1;;
esac
