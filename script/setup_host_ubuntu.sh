#!/bin/bash
set -eu
set -x

#---------------#
# Install tools
#---------------#

# UV
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv --python 3.12
source .venv/bin/activate

# Python libraries
uv pip install tomli gdown

# Core development dependencies
sudo apt update && sudo apt install -y llvm-dev clang libbpf-dev libclang-dev python3-pip libcxxopts-dev libboost-dev nvidia-cuda-dev libfmt-dev libspdlog-dev librdmacm-dev

# QEMU build dependencies
sudo apt install -y libglib2.0-dev libgcrypt20-dev zlib1g-dev \
    autoconf automake libtool bison flex libpixman-1-dev bc \
    make ninja-build libncurses-dev libelf-dev libssl-dev debootstrap \
    libcap-ng-dev libattr1-dev libslirp-dev libslirp0 libpmem-dev

# GCC 13 via gcc-toolset
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt update
sudo apt install -y gcc-13 g++-13

# CMake
cmake_required_version="4.2.3"
cmake_installed_version="$(cmake --version 2>/dev/null | awk 'NR == 1 { print $3 }' || true)"

if [ -n "${cmake_installed_version}" ] &&
    [ "$(printf '%s\n%s\n' "${cmake_required_version}" "${cmake_installed_version}" | sort -V | head -n 1)" = "${cmake_required_version}" ]; then
    echo "CMake ${cmake_installed_version} is already installed; skipping source build."
else
    echo "CMake ${cmake_required_version} or newer was not found; building it from source."
    mkdir -p temp
    cd temp
    curl -OL https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3.tar.gz
    tar zxvf cmake-4.2.3.tar.gz
    cd cmake-4.2.3/
    sudo ./bootstrap
    sudo make -j 4 && sudo make install -j 4
    cmake --version
    cd ../..
    sudo rm -rf temp
fi

#------------------#
# Build CXLMemSim
#------------------#
git submodule update --init --depth 1 submodules/CXLMemSim
cd submodules/CXLMemSim
git submodule update --init --depth 1 lib/qemu 

# Build submodules/CXLMemSim/lib/qemu
cd ./lib/qemu
mkdir -p build || echo "It's okay"
cd build
../configure --prefix=/usr/local --target-list=x86_64-softmmu --enable-debug --enable-libpmem --enable-slirp
make -j 4 && sudo make install -j 4
/usr/local/bin/qemu-system-x86_64 --version
cd ../../..

# Build submodules/CXLMemSim/workloads/gromacs
cd ./workloads/gromacs
sudo apt install -y openmpi-bin openmpi-common libopenmpi-dev
bash ./build.sh
cd ../../

# Build spdlog, which is for std::format in C++20
mkdir tmp || echo "It's okay"
cd tmp
curl -L https://github.com/gabime/spdlog/archive/refs/tags/v1.17.0.tar.gz -o spdlog_v1.17.0.tar.gz
tar zxvf spdlog_v1.17.0.tar.gz
cd spdlog-1.17.0
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DSPDLOG_USE_STD_FORMAT=ON \
	  -DCMAKE_CXX_COMPILER=g++-13 -DCMAKE_C_COMPILER=gcc-13 \
      -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build build -j 4
sudo cmake --install build -j 4
cd ../..
sudo rm -rf tmp

# Build CXLMemSim
mkdir build || echo "It's okay"
cd build
cmake -G Ninja .. -DSERVER_MODE=ON -DCMAKE_CXX_COMPILER=g++-13
ninja
cd ../../..  # go to OCEAN root

echo "Built CXLMemSim successfully."


#------------------#
# Copy QEMU images
#------------------#
mkdir build || echo "It's okay"
cd build

# Download bzImage
if [ -f bzImage ]; then
    echo "bzImage already exists; skipping download."
else
    gdown 1yKD0QG8x-wyFsVV1t5ZhNm_A3zUwlpQe
fi

# Download QEMU image
if [ -f qemu0.img ]; then
    echo "qemu0.img already exists; skipping download."
else
    gdown 1ga5CN3_H1qfReer99w_QcVOYb6R21JHI -O qemu0.img
fi

# Copy
if [ -f qemu1.img ]; then
    echo "qemu1.img already exists; skipping copy."
else
    cp qemu0.img qemu1.img
fi

echo "QEMU images should be here."
ls -alFh bzImage qemu0.img qemu1.img 

echo "If they are there, we should be ready to launch ../submodules/CXLMemSim/build/cxlmemsim_server and qemu virtual machines (sudo ../qemu_integration/launch_qemu_cxl0.sh)."
