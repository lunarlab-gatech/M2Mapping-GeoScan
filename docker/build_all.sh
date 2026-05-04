#!/bin/bash
# ============================================================================
# build_all.sh — full rebuild from a fresh container of m2mapping:cu128
# ----------------------------------------------------------------------------
# Use this when you've created a new container from the existing image and
# need to redo everything that was originally done by hand during debugging:
#
#   1. Install OpenCL C++ headers (rviz_map_plugin needs CL/cl2.hpp)
#   2. Write SophusConfig.cmake (Sophus a621ff doesn't ship one)
#   3. Patch kaolin AT_DISPATCH calls (.type() -> .scalar_type())
#   4. Patch M2Mapping utils.cpp (torch::linalg::eigh -> at::linalg_eigh)
#   5. Build livox_ros_driver + vikit
#   6. Build FAST-LIVO2
#   7. Build M2Mapping + RViz plugins
#
# Usage (inside the container):
#   bash build_all.sh
#
# Tunables:
#   JOBS=4 bash build_all.sh    # use 4 parallel jobs (default: nproc)
# ============================================================================
set -e

JOBS=${JOBS:-$(nproc)}
WS=/root/catkin_ws

echo ""
echo "============================================================"
echo "  M2Mapping + FAST-LIVO2 build, parallel jobs: ${JOBS}"
echo "============================================================"
echo ""

# ----------------------------------------------------------------------------
# Step 1 — OS-level fixes
# ----------------------------------------------------------------------------

# 1a. OpenCL C++ headers (CL/cl2.hpp). Needed by rviz_map_plugin. Idempotent —
# apt installs it once, subsequent runs are no-ops.
echo "==> [prep 1/4] Installing OpenCL C++ headers..."
if ! dpkg -s opencl-clhpp-headers >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        opencl-clhpp-headers \
        ocl-icd-opencl-dev
    rm -rf /var/lib/apt/lists/*
else
    echo "    already installed, skipping"
fi

# 1b. SophusConfig.cmake — old Sophus a621ff doesn't generate one, so
# find_package(Sophus) downstream fails without this file.
echo "==> [prep 2/4] Writing SophusConfig.cmake..."
if [ ! -f /usr/local/lib/cmake/Sophus/SophusConfig.cmake ]; then
    mkdir -p /usr/local/lib/cmake/Sophus
    cat > /usr/local/lib/cmake/Sophus/SophusConfig.cmake <<'SOPHUSCFG'
# Manual SophusConfig.cmake for Sophus a621ff (old commit doesn't ship one)
set(Sophus_FOUND TRUE)
set(Sophus_INCLUDE_DIRS "/usr/local/include")
set(Sophus_LIBRARIES "/usr/local/lib/libSophus.so")

if(NOT TARGET Sophus::Sophus)
  add_library(Sophus::Sophus SHARED IMPORTED)
  set_target_properties(Sophus::Sophus PROPERTIES
    IMPORTED_LOCATION "/usr/local/lib/libSophus.so"
    INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include"
  )
endif()
SOPHUSCFG
else
    echo "    already exists, skipping"
fi

# ----------------------------------------------------------------------------
# Step 2 — Source patches (idempotent — sed on already-patched code is no-op)
# ----------------------------------------------------------------------------

# 2a. kaolin: AT_DISPATCH_*(tensor.type(), ...) -> .scalar_type()
echo "==> [prep 3/4] Patching kaolin AT_DISPATCH calls..."
find ${WS}/src/M2Mapping/submodules/kaolin_wisp_cpp \
     \( -name '*.cu' -o -name '*.cpp' -o -name '*.cuh' -o -name '*.h' -o -name '*.hpp' \) \
     -exec sed -i '/AT_DISPATCH_/s/\.type()/.scalar_type()/g' {} +

# 2b. M2Mapping utils.cpp: torch::linalg::xxx -> at::linalg_xxx
# (LibTorch 2.7+cu128 doesn't ship <torch/linalg.h>)
echo "==> [prep 4/4] Patching M2Mapping utils.cpp linalg calls..."
sed -i 's/torch::linalg::\([a-z_]*\)/at::linalg_\1/g' \
    ${WS}/src/M2Mapping/include/utils/utils.cpp

# Strip a stale `#include <torch/linalg.h>` line if a previous run added one.
sed -i '/^#include <torch\/linalg\.h>$/d' \
    ${WS}/src/M2Mapping/include/utils/utils.cpp

# ----------------------------------------------------------------------------
# Step 3 — Build (in dependency order)
# ----------------------------------------------------------------------------
source /opt/ros/noetic/setup.bash
cd ${WS}

# 3a. ROS-side dependencies that FAST-LIVO2 and M2Mapping link against.
# Build these first and source devel/ before the next pass so catkin can find
# them via find_package().
echo ""
echo "==> [1/3] Building livox_ros_driver and rpg_vikit..."
catkin_make -j${JOBS} --pkg livox_ros_driver vikit_common vikit_ros

source ${WS}/devel/setup.bash

# 3b. FAST-LIVO2.
echo ""
echo "==> [2/3] Building FAST-LIVO2 (fast_livo)..."
catkin_make -j${JOBS} --pkg fast_livo

# 3c. M2Mapping + RViz plugins (heaviest — pulls tiny-cuda-nn + LibTorch).
# If this OOMs or hangs, rerun with JOBS=4 or JOBS=2.
echo ""
echo "==> [3/3] Building M2Mapping and RViz plugins (this is the slow one)..."
catkin_make -j${JOBS} \
    -DENABLE_ROS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DTCNN_CUDA_ARCHITECTURES=120

echo ""
echo "============================================================"
echo "  Build complete!"
echo "============================================================"
echo ""
echo "  Binaries:"
echo "    ${WS}/devel/lib/fast_livo/fastlivo_mapping"
echo "    ${WS}/devel/lib/neural_mapping/neural_mapping_node"
echo "    ${WS}/devel/lib/livox_ros_driver/livox_ros_driver_node"
echo ""
echo "  Source the workspace in new shells with:"
echo "    source ${WS}/devel/setup.bash"
echo "  (your /root/.bashrc already does this)"
echo ""