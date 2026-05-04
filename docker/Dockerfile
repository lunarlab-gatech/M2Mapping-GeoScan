# ============================================================================
# Comprehensive Dockerfile for the FAST-LIVO2 -> M2Mapping pipeline
# Version of Lingjun
# ----------------------------------------------------------------------------
# Target host : Alienware laptop, Ubuntu 22.04, NVIDIA driver >= 570, RTX 5090
# Container   : Ubuntu 20.04 + CUDA 12.8 + cuDNN + ROS Noetic + LibTorch 2.7.0
#
# What this builds:
#   1. ROS Noetic + LibTorch + Miniconda (for Open3D)
#   2. Sophus (commit a621ff, the non-templated double-only version)
#   3. livox_ros_driver  (for deserializing Livox CustomMsg in rosbags)
#   4. xuankuzcr/rpg_vikit  (vikit_common + vikit_ros — the FAST-LIVO2 fork)
#   5. jianhengLiu/FAST-LIVO2  (neural_mapping branch — modified for M2Mapping)
#   6. hku-mars/M2Mapping  (with submodules; includes tiny-cuda-nn)
#   7. RViz plugins for M2Mapping visualization
#
# Why these specific versions:
#   - RTX 5090 is Blackwell (sm_120); requires CUDA 12.8+. CUDA 11.8 won't work.
#   - LibTorch 2.7.0+cu128 is the matching cxx11-ABI build for CUDA 12.8.
#   - ROS Noetic only ships for Ubuntu 20.04 → container OS is 20.04 even
#     though host is 22.04 (containers are isolated, this is fine).
#   - Sophus pinned at a621ff per FAST-LIVO2's README (non-templated version
#     that the codebase actually links against).
#   - rpg_vikit is xuankuzcr's fork, NOT the upstream RPG one — they differ.
#
# IMPORTANT: We DO NOT run catkin_make inside the image. Cloning is done here,
# building is done at first `docker run` via /usr/local/bin/build_all.sh.
# This keeps the image small and lets you see/debug build errors interactively.
# ============================================================================

FROM nvidia/cuda:12.8.0-cudnn-devel-ubuntu20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# CUDA architecture for RTX 5090 (Blackwell sm_120)
ENV CUDA_ARCHITECTURES=120
ENV CMAKE_CUDA_ARCHITECTURES=120
ENV TCNN_CUDA_ARCHITECTURES=120
ENV TORCH_CUDA_ARCH_LIST="12.0"

# ----------------------------------------------------------------------------
# Step 1: Base system + libraries (PCL, Eigen, OpenCV, Boost, etc.)
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl wget git \
        gnupg2 lsb-release software-properties-common \
        build-essential pkg-config \
        zip unzip \
        vim nano sudo \
        libdw-dev \
        libgoogle-glog-dev \
        libgflags-dev \
        libssl-dev \
        libeigen3-dev \
        libyaml-cpp-dev \
        libboost-all-dev \
        libpcl-dev \
        libopencv-dev \
        libgoogle-perftools-dev \
        libtbb-dev \
        python3-pip python3-dev python3-numpy \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# Step 2: Modern CMake (M2Mapping needs >= 3.23 for the LibTorch CUDA toolchain)
# ----------------------------------------------------------------------------
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9-linux-x86_64.sh \
    && bash cmake-3.27.9-linux-x86_64.sh --skip-license --prefix=/usr/local \
    && rm cmake-3.27.9-linux-x86_64.sh \
    && cmake --version

# ----------------------------------------------------------------------------
# Step 3: ROS Noetic + ros packages needed by FAST-LIVO2 and M2Mapping
# ----------------------------------------------------------------------------
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu focal main" \
        > /etc/apt/sources.list.d/ros-noetic.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        ros-noetic-desktop-full \
        ros-noetic-mesh-msgs \
        ros-noetic-rviz-animated-view-controller \
        ros-noetic-hdf5-map-io \
        ros-noetic-pcl-ros \
        ros-noetic-pcl-conversions \
        ros-noetic-eigen-conversions \
        ros-noetic-tf-conversions \
        ros-noetic-cv-bridge \
        ros-noetic-image-transport \
        python3-catkin-tools \
        python3-rosdep \
        python3-rosinstall \
        python3-rosinstall-generator \
        python3-wstool \
    && rosdep init && rosdep update \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# Step 4: Python 3.10 via Miniconda for M2Mapping eval scripts (Open3D needs it)
# Conda Python lives at /opt/conda; ROS keeps using system python3.8.
# ----------------------------------------------------------------------------
RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-py310_24.9.2-0-Linux-x86_64.sh \
        -O /tmp/miniconda.sh \
    && bash /tmp/miniconda.sh -b -p /opt/conda \
    && rm /tmp/miniconda.sh \
    && /opt/conda/bin/conda clean -afy \
    && ln -sf /opt/conda/bin/python3 /usr/local/bin/python3.10 \
    && ln -sf /opt/conda/bin/pip      /usr/local/bin/pip3.10

RUN /opt/conda/bin/pip install --no-cache-dir \
        open3d==0.18.0 \
        numpy==1.24.4 \
        scipy \
        matplotlib \
        opencv-python \
        trimesh \
        plyfile \
        tqdm

# ----------------------------------------------------------------------------
# Step 5: LibTorch 2.7.0 + CUDA 12.8 (cxx11 ABI, matches OpenCV's ABI)
# ----------------------------------------------------------------------------
WORKDIR /opt
RUN wget -q https://download.pytorch.org/libtorch/cu128/libtorch-cxx11-abi-shared-with-deps-2.7.0%2Bcu128.zip \
        -O libtorch.zip \
    && unzip -q libtorch.zip \
    && rm libtorch.zip

ENV Torch_DIR=/opt/libtorch/share/cmake/Torch
ENV CMAKE_PREFIX_PATH=/opt/libtorch
ENV LD_LIBRARY_PATH=/opt/libtorch/lib

# ----------------------------------------------------------------------------
# Step 6: Sophus (commit a621ff — the non-templated/double-only version that
# FAST-LIVO2 explicitly requires per its README). NOT a catkin package, so we
# install it system-wide to /usr/local.
#
# Patch needed: at this commit, sophus/so2.cpp uses an old std::complex idiom
#   unit_complex_.real() = 1.;
# which compiled in C++03/early-C++11 but is rejected by modern compilers
# because std::complex::real() returns an rvalue, not an assignable lvalue.
# We rewrite both lines to use the setter form: unit_complex_.real(1.);
# We also drop -Werror so any other harmless warnings don't break the build.
# ----------------------------------------------------------------------------
WORKDIR /opt
RUN git clone https://github.com/strasdat/Sophus.git sophus_src \
    && cd sophus_src \
    && git checkout a621ff \
    && sed -i \
        -e 's|unit_complex_\.real() = 1\.|unit_complex_.real(1.)|' \
        -e 's|unit_complex_\.imag() = 0\.|unit_complex_.imag(0.)|' \
        sophus/so2.cpp \
    && sed -i 's|-Werror||g' CMakeLists.txt \
    && mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && cd /opt && rm -rf sophus_src

# ----------------------------------------------------------------------------
# Step 7: (Optional) mimalloc — FAST-LIVO2's CMake will pick it up automatically
# and use it for faster allocation. The build won't fail if this is absent.
# ----------------------------------------------------------------------------
WORKDIR /opt
RUN git clone --depth 1 --branch v2.1.7 https://github.com/microsoft/mimalloc.git mimalloc_src \
    && cd mimalloc_src && mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release -DMI_BUILD_TESTS=OFF \
    && make -j$(nproc) && make install \
    && ldconfig \
    && cd /opt && rm -rf mimalloc_src

# ----------------------------------------------------------------------------
# Step 8: Catkin workspace skeleton + clone all source repos.
# ----------------------------------------------------------------------------
WORKDIR /root
RUN mkdir -p /root/catkin_ws/src

WORKDIR /root/catkin_ws/src

# 8a. Livox ROS driver (provides livox_ros_driver/CustomMsg). FAST-LIVO2 uses
#     driver v1, NOT v2.
RUN git clone https://github.com/Livox-SDK/livox_ros_driver.git

# 8b. xuankuzcr's rpg_vikit fork — FAST-LIVO2 README is explicit:
#     "Different from the one used in fast-livo1"
RUN git clone https://github.com/xuankuzcr/rpg_vikit.git

# 8c. Modified FAST-LIVO2 (jianhengLiu fork, neural_mapping branch)
RUN git clone --branch neural_mapping https://github.com/jianhengLiu/FAST-LIVO2.git

# 8d. M2Mapping with all submodules (tiny-cuda-nn, etc.)
RUN git clone --recursive https://github.com/hku-mars/M2Mapping.git

# 8e. RViz visualization plugins for M2Mapping
RUN git clone https://github.com/jianhengLiu/rviz_map_plugin.git \
    && git clone https://github.com/jianhengLiu/rviz_fps_plugin.git

# ----------------------------------------------------------------------------
# Step 9: Build script — run this once inside the container after `docker run`.
# It builds packages in dependency order so catkin can find them.
# ----------------------------------------------------------------------------
RUN cat > /usr/local/bin/build_all.sh <<'EOF'
#!/bin/bash
# Builds livox_ros_driver, rpg_vikit, FAST-LIVO2, then M2Mapping, in order.
# Run this once after starting the container. Re-running is safe (catkin
# incremental builds will skip what's already up to date).
set -e

source /opt/ros/noetic/setup.bash
cd /root/catkin_ws

JOBS=${JOBS:-$(nproc)}
echo "==> Building with -j${JOBS}"

# ---- Pass 1: ROS-side deps that FAST-LIVO2 needs to find at catkin time ----
echo "==> [1/3] Building livox_ros_driver and rpg_vikit..."
catkin_make -j${JOBS} --pkg livox_ros_driver vikit_common vikit_ros

source /root/catkin_ws/devel/setup.bash

# ---- Pass 2: FAST-LIVO2 ----
echo "==> [2/3] Building FAST-LIVO2 (fast_livo)..."
catkin_make -j${JOBS} --pkg fast_livo

# ---- Pass 3: M2Mapping + RViz plugins (heaviest — tiny-cuda-nn + LibTorch) ----
# If this OOMs or hangs, lower JOBS:  JOBS=4 build_all.sh
echo "==> [3/3] Building M2Mapping and RViz plugins (this is the slow one)..."
catkin_make -j${JOBS} \
    -DENABLE_ROS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DTCNN_CUDA_ARCHITECTURES=120

echo ""
echo "==> Build complete!"
echo "    Workspace already auto-sourced in /root/.bashrc on next shell."
echo ""
EOF
RUN chmod +x /usr/local/bin/build_all.sh

# ----------------------------------------------------------------------------
# Step 10: Shell setup — auto-source ROS, workspace, and export env vars.
# ----------------------------------------------------------------------------
RUN cat >> /root/.bashrc <<'EOF'

# ---- M2Mapping / FAST-LIVO2 environment ----
source /opt/ros/noetic/setup.bash
[ -f /root/catkin_ws/devel/setup.bash ] && source /root/catkin_ws/devel/setup.bash

export Torch_DIR=/opt/libtorch/share/cmake/Torch
export CMAKE_PREFIX_PATH=/opt/libtorch:${CMAKE_PREFIX_PATH:-}
export LD_LIBRARY_PATH=/opt/libtorch/lib:${LD_LIBRARY_PATH:-}

# CUDA arch for RTX 5090 (Blackwell sm_120)
export TCNN_CUDA_ARCHITECTURES=120
export CMAKE_CUDA_ARCHITECTURES=120
export TORCH_CUDA_ARCH_LIST=12.0

cd /root/catkin_ws
EOF

WORKDIR /root/catkin_ws

CMD ["/bin/bash"]