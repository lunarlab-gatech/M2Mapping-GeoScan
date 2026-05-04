#!/bin/bash
# ============================================================================
# Helper script to build/run the M2Mapping + FAST-LIVO2 container.
#
# Usage:
#   ./run.sh build          # build the docker image
#   ./run.sh start          # start a container (interactive shell)
#   ./run.sh exec           # attach a new shell to running container
#   ./run.sh stop           # stop and remove the container
# ============================================================================

set -e

IMAGE_NAME="m2mapping:cu128"
CONTAINER_NAME="m2mapping"

build() {
    docker build -t "${IMAGE_NAME}" .
}

start() {
    # Allow the container to talk to your X server (for RViz)
    xhost +local:docker >/dev/null 2>&1 || true

    docker run -it \
        --name "${CONTAINER_NAME}" \
        --gpus all \
        --network host \
        --ipc host \
        --privileged \
        -e DISPLAY="${DISPLAY}" \
        -e QT_X11_NO_MITSHM=1 \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
        -v /home/lzhao360/Documents/real2sim2real:/root/real2sim2real \
        "${IMAGE_NAME}"
}

exec_shell() {
    docker exec -it "${CONTAINER_NAME}" /bin/bash
}

stop() {
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm   "${CONTAINER_NAME}" 2>/dev/null || true
}

case "${1:-}" in
    build) build ;;
    start) start ;;
    exec)  exec_shell ;;
    stop)  stop ;;
    *)     echo "Usage: $0 {build|start|exec|stop}"; exit 1 ;;
esac