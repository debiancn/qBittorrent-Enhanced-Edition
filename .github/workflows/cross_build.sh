#!/bin/bash -e

# This scrip is for building AppImage
# Please run this scrip in docker image: ubuntu:20.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:20.04 /build/.github/workflows/cross_build.sh
# If you need keep store build cache in docker volume, just like:
#   $ docker volume create qbee-nox-cache
#   $ docker run --rm -v `git rev-parse --show-toplevel`:/build -v qbee-nox-cache:/var/cache/apt -v qbee-nox-cache:/usr/src ubuntu:20.04 /build/.github/workflows/cross_build.sh
# Artifacts will copy to the same directory.

set -o pipefail

# match qt version prefix. E.g 5 --> 5.15.2, 5.12 --> 5.12.10
export QT_VER_PREFIX="6"
export LIBTORRENT_BRANCH="RC_2_0"

# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  source /etc/os-release
  cat >/etc/apt/sources.list <<EOF
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
  export PIP_INDEX_URL="https://repo.huaweicloud.com/repository/pypi/simple"
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y \
  curl \
  git \
  make \
  g++ \
  unzip \
  zip \
  pkg-config \
  python3 \
  python3-requests \
  python3-semantic-version \
  python3-lxml \
  python3-pip

# value from: https://musl.cc/ (without -cross or -native)
export CROSS_HOST="${CROSS_HOST:-arm-linux-musleabi}"

# OPENSSL_COMPILER value is from openssl source: ./Configure LIST
# QT_DEVICE and QT_DEVICE_OPTIONS value are from https://github.com/qt/qtbase/tree/dev/mkspecs/devices/
case "${CROSS_HOST}" in
arm-linux*)
  export OPENSSL_COMPILER=linux-armv4
  ;;
aarch64-linux*)
  export OPENSSL_COMPILER=linux-aarch64
  ;;
mips-linux* | mipsel-linux*)
  export OPENSSL_COMPILER=linux-mips32
  ;;
mips64-linux* | mips64el-linux*)
  export OPENSSL_COMPILER=linux64-mips64
  ;;
x86_64-linux*)
  export OPENSSL_COMPILER=linux-x86_64
  ;;
x86_64-*-mingw*)
  export OPENSSL_COMPILER=mingw64
  ;;
i686-*-mingw*)
  export OPENSSL_COMPILER=mingw
  ;;
*)
  export OPENSSL_COMPILER=gcc
  ;;
esac

export QT_VER_PREFIX="6"
export LIBTORRENT_BRANCH="RC_2_0"
export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
# strip all compiled files by default
export CFLAGS='-s'
export CXXFLAGS='-s'

TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_HOST}" in
*"mingw"*)
  TARGET_HOST=Windows
  apt install -y wine
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=Linux
  apt install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/opt/qt/lib/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${CROSS_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"
SELF_DIR="$(dirname "$(readlink -f "${0}")")"

mkdir -p "${CROSS_ROOT}" "/usr/src"

retry() {
  # max retry 5 times
  try=5
  # sleep 3s every retry
  sleep_time=3
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

prepare_cmake() {
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://ghproxy.com/${cmake_binary_url}"
      cmake_sha256_url="https://ghproxy.com/${cmake_sha256_url}"
    fi
    if [ -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd /usr/src
      if ! retry curl -ksSL --compressed "${cmake_sha256_url}" \| grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" \| sha256sum -c; then
        rm -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry curl -kLo "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
}

prepare_ninja() {
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://ghproxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok" ]; then
      rm -f "/usr/src/ninja-${ninja_ver}-linux.zip"
      retry curl -kLC- -o "/usr/src/ninja-${ninja_ver}-linux.zip" "${ninja_binary_url}"
      touch "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok"
    fi
    unzip -d /usr/local/bin "/usr/src/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_toolchain() {
  if [ -f "/usr/src/${CROSS_HOST}-cross.tgz" ]; then
    cd /usr/src/
    if ! curl -ksSL --compressed http://musl.cc/SHA512SUMS | grep "${CROSS_HOST}-cross.tgz" | head -1 | sha512sum -c; then
      rm -f "/usr/src/${CROSS_HOST}-cross.tgz"
    fi
  fi
  if [ ! -f "/usr/src/${CROSS_HOST}-cross.tgz" ]; then
    retry curl -kLC- -o "/usr/src/${CROSS_HOST}-cross.tgz" "http://musl.cc/${CROSS_HOST}-cross.tgz"
  fi
  tar -zxf "/usr/src/${CROSS_HOST}-cross.tgz" --transform='s|^\./||S' --strip-components=1 -C "${CROSS_ROOT}"
  # mingw does not contains posix thread support: https://github.com/meganz/mingw-std-threads
  # libtorrent need this feature, see issue: https://github.com/arvidn/libtorrent/issues/5330
  if [ x"${TARGET_HOST}" = xWindows ]; then
    if [ ! -d "/usr/src/mingw-std-threads" ]; then
      mingw_std_threads_git_url="https://github.com/meganz/mingw-std-threads.git"
      if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
        mingw_std_threads_git_url="https://ghproxy.com/${mingw_std_threads_git_url}"
      fi
      git clone --depth 1 "${mingw_std_threads_git_url}" "/usr/src/mingw-std-threads"
    fi
    cd "/usr/src/mingw-std-threads"
    git pull
    cp -fv /usr/src/mingw-std-threads/*.h "${CROSS_PREFIX}/include"
  fi
}

prepare_zlib() {
  zlib_ver="$(retry curl -ksSL --compressed https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
  echo "zlib version ${zlib_ver}"
  if [ ! -f "/usr/src/zlib-${zlib_ver}/.unpack_ok" ]; then
    mkdir -p "/usr/src/zlib-${zlib_ver}"
    zlib_latest_url="https://sourceforge.net/projects/libpng/files/zlib/${zlib_ver}/zlib-${zlib_ver}.tar.xz/download"
    retry curl -kL "${zlib_latest_url}" \| tar -Jxf - --strip-components=1 -C "/usr/src/zlib-${zlib_ver}"
    touch "/usr/src/zlib-${zlib_ver}/.unpack_ok"
  fi
  cd "/usr/src/zlib-${zlib_ver}"

  if [ x"${TARGET_HOST}" = xWindows ]; then
    make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
  else
    CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
    make -j$(nproc)
    make install
  fi
}

prepare_ssl() {
  openssl_filename="$(retry curl -ksSL --compressed https://www.openssl.org/source/ \| grep -o "'href=\"openssl-3.*tar.gz\"'" \| grep -o "'[^\"]*.tar.gz'")"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  echo "OpenSSL version ${openssl_ver}"
  if [ ! -f "/usr/src/openssl-${openssl_ver}/.unpack_ok" ]; then
    openssl_download_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      openssl_download_url="https://ghproxy.com/${openssl_download_url}"
    fi
    mkdir -p "/usr/src/openssl-${openssl_ver}/"
    retry curl -kL "${openssl_download_url}" \| tar -zxf - --strip-components=1 -C "/usr/src/openssl-${openssl_ver}/"
    touch "/usr/src/openssl-${openssl_ver}/.unpack_ok"
  fi
  cd "/usr/src/openssl-${openssl_ver}/"
  ./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}"
  make -j$(nproc)
  make install_sw
  if [ -f "${CROSS_PREFIX}/lib64/libssl.a" ]; then
    cp -rfv "${CROSS_PREFIX}"/lib64/. "${CROSS_PREFIX}/lib"
  fi
  if [ -f "${CROSS_PREFIX}/lib32/libssl.a" ]; then
    cp -rfv "${CROSS_PREFIX}"/lib32/. "${CROSS_PREFIX}/lib"
  fi
}

prepare_boost() {
  boost_ver="$(retry curl -ksSL --compressed https://www.boost.org/users/download/ \| grep "'>Version\s*'" \| sed -r "'s/.*Version\s*([^<]+).*/\1/'" \| head -1)"
  echo "Boost version ${boost_ver}"
  if [ ! -f "/usr/src/boost-${boost_ver}/.unpack_ok" ]; then
    boost_latest_url="https://sourceforge.net/projects/boost/files/boost/${boost_ver}/boost_${boost_ver//./_}.tar.bz2/download"
    mkdir -p "/usr/src/boost-${boost_ver}/"
    retry curl -kL "${boost_latest_url}" \| tar -jxf - -C "/usr/src/boost-${boost_ver}/" --strip-components 1
    touch "/usr/src/boost-${boost_ver}/.unpack_ok"
  fi
  cd "/usr/src/boost-${boost_ver}/"
  echo "using gcc : cross : ${CROSS_HOST}-g++ ;" >~/user-config.jam
  if [ ! -f ./b2 ]; then
    ./bootstrap.sh
  fi
  ./b2 -d0 -q install --prefix="${CROSS_PREFIX}" --with-system toolset=gcc-cross variant=release link=static runtime-link=static
  cd "/usr/src/boost-${boost_ver}/tools/build"
  if [ ! -f ./b2 ]; then
    ./bootstrap.sh
  fi
  ./b2 -d0 -q install --prefix="${CROSS_ROOT}"
}

prepare_qt() {
  qt_major_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  qt_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/${qt_major_ver}/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  echo "Using qt version: ${qt_ver}"
  mkdir -p "/usr/src/qtbase-${qt_ver}" "/usr/src/qttools-${qt_ver}"
  if [ ! -f "/usr/src/qt-host/${qt_ver}/gcc_64/bin/qt.conf" ]; then
    pip3 install py7zr
    retry curl -ksSL --compressed "https://cdn.jsdelivr.net/gh/engnr/qt-downloader@master/qt-downloader" \| python3 - linux desktop "${qt_ver}" gcc_64 -o "/usr/src/qt-host" -m qtbase qttools icu
  fi
  if [ ! -f "/usr/src/qtbase-${qt_ver}/.unpack_ok" ]; then
    qtbase_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
    retry curl -kL "${qtbase_url}" \| tar Jxf - -C "/usr/src/qtbase-${qt_ver}" --strip-components 1
    touch "/usr/src/qtbase-${qt_ver}/.unpack_ok"
  fi
  cd "/usr/src/qtbase-${qt_ver}"
  rm -fr CMakeCache.txt CMakeFiles
  if [ x"${TARGET_HOST}" = xWindows ]; then
    QT_BASE_EXTRA_CONF='-xplatform win32-g++'
  fi

  ./configure \
    -prefix "${CROSS_PREFIX}/opt/qt/" \
    -qt-host-path "/usr/src/qt-host/${qt_ver}/gcc_64/" \
    -release \
    -static \
    -c++std c++17 \
    -optimize-size \
    -openssl \
    -openssl-linked \
    -no-gui \
    -no-dbus \
    -no-widgets \
    -no-feature-testlib \
    -no-feature-animation \
    -feature-optimize_full \
    ${QT_BASE_EXTRA_CONF} \
    -device-option "CROSS_COMPILE=${CROSS_HOST}-" \
    -- \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_C_COMPILER="${CROSS_HOST}-gcc" \
    -DCMAKE_SYSROOT="${CROSS_PREFIX}" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-g++"
  cmake --build . --parallel
  cmake --install .
  export QT_BASE_DIR="${CROSS_PREFIX}/opt/qt"
  export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
  export PATH="${QT_BASE_DIR}/bin:${PATH}"
}

prepare_libtorrent() {
  echo "libtorrent-rasterbar branch: ${LIBTORRENT_BRANCH}"
  if [ ! -d "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/" ]; then
    libtorrent_git_url="https://github.com/arvidn/libtorrent.git"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      libtorrent_git_url="https://ghproxy.com/${libtorrent_git_url}"
    fi
    retry git clone --depth 1 --recursive --shallow-submodules --branch "${LIBTORRENT_BRANCH}" \
      "${libtorrent_git_url}" \
      "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
  fi
  cd "/usr/src/libtorrent-rasterbar-${LIBTORRENT_BRANCH}/"
  git pull
  rm -fr build/CMakeCache.txt
  # TODO: solve mingw build
  if [ x"${TARGET_HOST}" = xWindows ]; then
    find -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0 |
      xargs -0 -r sed -i 's/Windows\.h/windows.h/g;
                          s/Shellapi\.h/shellapi.h/g;
                          s/Shlobj\.h/shlobj.h/g;
                          s/Ntsecapi\.h/ntsecapi.h/g;
                          s/#include\s*<condition_variable>/#include "mingw.condition_variable.h"/g;
                          s/#include\s*<future>/#include "mingw.future.h"/g;
                          s/#include\s*<invoke>/#include "mingw.invoke.h"/g;
                          s/#include\s*<mutex>/#include "mingw.mutex.h"/g;
                          s/#include\s*<shared_mutex>/#include "mingw.shared_mutex.h"/g;
                          s/#include\s*<thread>/#include "mingw.thread.h"/g'
  fi
  cmake \
    -B build \
    -G "Ninja" \
    -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -Dstatic_runtime=on \
    -DBUILD_SHARED_LIBS=off \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_SYSROOT="${CROSS_PREFIX}" \
    -DCMAKE_C_COMPILER="${CROSS_HOST}-gcc" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-g++"
  cmake --build build
  cmake --install build
}

build_qbittorrent() {
  cd "${SELF_DIR}/../../"
  rm -fr build/CMakeCache.txt
  cmake \
    -B build \
    -G "Ninja" \
    -DQT6=ON \
    -DGUI=off \
    -DQT_HOST_PATH="/usr/src/qt-host/${qt_ver}/gcc_64/" \
    -DSTACKTRACE=off \
    -DBUILD_SHARED_LIBS=off \
    -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
    -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
    -DCMAKE_BUILD_TYPE="Release" \
    -DCMAKE_CXX_STANDARD="17" \
    -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
    -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
    -DCMAKE_SYSROOT="${CROSS_PREFIX}" \
    -DCMAKE_CXX_COMPILER="${CROSS_HOST}-g++" \
    -DCMAKE_EXE_LINKER_FLAGS="-static"
  cmake --build build
  cmake --install build
  if [ x"${TARGET_HOST}" = xWindows ]; then
    cp -fv "src/release/qbittorrent-nox.exe" /tmp/
  else
    cp -fv "${CROSS_PREFIX}/bin/qbittorrent-nox" /tmp/
  fi
}

prepare_cmake
prepare_ninja
prepare_toolchain
prepare_zlib
prepare_ssl
prepare_boost
prepare_qt
prepare_libtorrent
build_qbittorrent

# check
"${RUNNER_CHECKER}" /tmp/qbittorrent-nox* --version 2>/dev/null

# archive qbittorrent
zip -j9v "${SELF_DIR}/qbittorrent-enhanced-nox_${CROSS_HOST}_static.zip" /tmp/qbittorrent-nox*
