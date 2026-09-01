#!/bin/bash
set -x
set -Eeuo pipefail

# 始终从仓库根目录执行，避免调用位置不同导致路径错误。
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# 按需克隆依赖仓库；已正确初始化时跳过，目录异常时停止。
clone_if_missing() {
    local repository_url=$1
    local destination=$2
    local existing_url
    local destination_parent

    if git -C "$destination" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
        git -C "$destination" rev-parse --verify HEAD >/dev/null 2>&1; then
        existing_url=$(git -C "$destination" remote get-url origin)
        if [ "$existing_url" != "$repository_url" ] && [ "$existing_url" != "${repository_url%.git}.git" ]; then
            echo "Error: $destination has unexpected origin: $existing_url" >&2
            return 1
        fi
        echo "$destination is already initialized; skipping clone."
        return 0
    fi

    if [ -e "$destination" ]; then
        echo "Error: $destination exists but is not a Git repository." >&2
        return 1
    fi

    destination_parent=$(dirname "$destination")
    mkdir -p "$destination_parent"
    (
        # 先克隆到临时目录，成功后再移动，避免留下不完整仓库。
        local clone_work_dir
        clone_work_dir=$(mktemp -d "$destination_parent/.setup-clone.XXXXXX")
        trap 'rm -rf -- "$clone_work_dir"' EXIT
        git clone "$repository_url" "$clone_work_dir/repository"
        mv "$clone_work_dir/repository" "$destination"
    )
}

clone_if_missing https://github.com/CXLMemUring/qemu lib/qemu
clone_if_missing https://github.com/CXLMemUring/tigon workloads/tigon

# 安装项目、BPF、RDMA、QEMU 构建及 Python 工具所需的基础依赖。
sudo apt update && sudo apt install -y llvm-dev clang libbpf-dev libclang-dev python3-pip libcxxopts-dev libboost-dev nvidia-cuda-dev libfmt-dev libspdlog-dev librdmacm-dev
python3 -m pip install --break-system-packages tomli
python3 -m pip install --break-system-packages gdown
sudo apt-get install -y libglib2.0-dev libgcrypt20-dev zlib1g-dev \
    autoconf automake libtool bison flex libpixman-1-dev bc \
    make ninja-build libncurses-dev libelf-dev libssl-dev debootstrap \
    libcap-ng-dev libattr1-dev libslirp-dev libslirp0 libpmem-dev

# 添加 Ubuntu 工具链 PPA 并安装 GCC/G++ 13。
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt update
sudo apt install -y gcc-13 g++-13

# 仅在 CMake 缺失或版本低于要求时从源码构建。
required_cmake_version=4.2.3
installed_cmake_version=""
if command -v cmake >/dev/null 2>&1; then
    installed_cmake_version=$(cmake --version | awk 'NR == 1 { print $3 }')
fi

if [ -z "$installed_cmake_version" ] || ! dpkg --compare-versions "$installed_cmake_version" ge "$required_cmake_version"; then
    # 使用临时构建目录，并确保失败退出时也能清理。
    cmake_build_dir=$(mktemp -d)
    trap 'rm -rf -- "$cmake_build_dir"' EXIT

    (
        cd "$cmake_build_dir"
        wget "https://github.com/Kitware/CMake/releases/download/v${required_cmake_version}/cmake-${required_cmake_version}.tar.gz"
        tar zxvf "cmake-${required_cmake_version}.tar.gz"
        cd "cmake-${required_cmake_version}"
        ./bootstrap
        make -j"$(nproc)"
        sudo make install
    )

    rm -rf -- "$cmake_build_dir"
    trap - EXIT
else
    echo "CMake $installed_cmake_version is already installed; skipping CMake build."
fi

cmake --version

# 配置、并行编译并安装项目定制的 x86_64 QEMU。
cd "$repo_root/lib/qemu"
mkdir -p build
cd build
../configure --prefix=/usr/local --target-list=x86_64-softmmu --enable-debug --enable-libpmem --enable-slirp
make -j"$(nproc)"
sudo make install
/usr/local/bin/qemu-system-x86_64 --version
