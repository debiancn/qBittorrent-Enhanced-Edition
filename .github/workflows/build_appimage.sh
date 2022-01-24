#!/bin/bash -e

# This scrip is for building AppImage
# Please run this scrip in docker image: ubuntu:16.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:16.04 /build/.github/workflows/build_appimage.sh
# If you need keep store build cache in docker volume, just like:
#   $ docker volume create qbee-cache
#   $ docker run --rm -v `git rev-parse --show-toplevel`:/build -v qbee-cache:/var/cache/apt -v qbee-cache:/usr/src ubuntu:16.04 /build/.github/workflows/build_appimage.sh
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
apt install -y software-properties-common apt-transport-https
apt-add-repository -y ppa:savoury1/backports
apt-add-repository -y ppa:savoury1/toolchain
add-apt-repository -y ppa:savoury1/qt-5-15
add-apt-repository -y ppa:savoury1/gtk-xenial

if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  sed -i 's@http://ppa.launchpad.net@https://launchpad.proxy.ustclug.org@' /etc/apt/sources.list.d/*.list
fi

apt update
apt install -y \
  curl \
  git \
  unzip \
  pkg-config \
  libssl-dev \
  libzstd-dev \
  zlib1g-dev \
  libbrotli-dev \
  libxcb1-dev \
  libicu-dev \
  libgtk-3-dev \
  g++-8 \
  build-essential \
  libgl1-mesa-dev \
  libfontconfig1-dev \
  libfreetype6-dev \
  libx11-dev \
  libx11-xcb-dev \
  libxext-dev \
  libxfixes-dev \
  libxi-dev \
  libxrender-dev \
  libxcb1-dev \
  libxcb-glx0-dev \
  libxcb-keysyms1-dev \
  libxcb-image0-dev \
  libxcb-shm0-dev \
  libxcb-icccm4-dev \
  libxcb-sync-dev \
  libxcb-xfixes0-dev \
  libxcb-shape0-dev \
  libxcb-randr0-dev \
  libxcb-render-util0-dev \
  libxcb-util-dev \
  libxcb-xinerama0-dev \
  libxcb-xkb-dev \
  libxkbcommon-dev \
  libxkbcommon-x11-dev

apt autoremove --purge -y
export CC=gcc-8
export CXX=g++-8
# strip all compiled files by default
export CFLAGS='-s'
export CXXFLAGS='-s'
# Force refresh ld.so.cache
ldconfig
SELF_DIR="$(dirname "$(readlink -f "${0}")")"

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

# install cmake and ninja-build
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

# install qt
qt_major_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
qt_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/${qt_major_ver}/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
echo "Using qt version: ${qt_ver}"
mkdir -p "/usr/src/qtbase-${qt_ver}" "/usr/src/qttools-${qt_ver}" "/usr/src/qtsvg-${qt_ver}"
if [ ! -f "/usr/src/qtbase-${qt_ver}/.unpack_ok" ]; then
  qtbase_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
  retry curl -kSL --compressed "${qtbase_url}" \| tar Jxf - -C "/usr/src/qtbase-${qt_ver}" --strip-components 1
  touch "/usr/src/qtbase-${qt_ver}/.unpack_ok"
fi
cd "/usr/src/qtbase-${qt_ver}"
rm -fr CMakeCache.txt CMakeFiles
./configure \
  -ltcg \
  -release \
  -c++std c++17 \
  -optimize-size \
  -openssl-linked \
  -no-opengl \
  -no-directfb \
  -no-linuxfb \
  -no-eglfs \
  -no-feature-testlib \
  -no-feature-vnc \
  -feature-optimize_full
cmake --build . --parallel
cmake --install .
export QT_BASE_DIR="$(ls -rd /usr/local/Qt-* | head -1)"
export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
export PATH="${QT_BASE_DIR}/bin:${PATH}"
if [ ! -f "/usr/src/qtsvg-${qt_ver}/.unpack_ok" ]; then
  qtsvg_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtsvg-everywhere-src-${qt_ver}.tar.xz"
  retry curl -kSL --compressed "${qtsvg_url}" \| tar Jxf - -C "/usr/src/qtsvg-${qt_ver}" --strip-components 1
  touch "/usr/src/qtsvg-${qt_ver}/.unpack_ok"
fi
cd "/usr/src/qtsvg-${qt_ver}"
rm -fr CMakeCache.txt
"${QT_BASE_DIR}/bin/qt-configure-module" .
cmake --build . --parallel
cmake --install .
if [ ! -f "/usr/src/qttools-${qt_ver}/.unpack_ok" ]; then
  qttools_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qttools-everywhere-src-${qt_ver}.tar.xz"
  retry curl -kSL --compressed "${qttools_url}" \| tar Jxf - -C "/usr/src/qttools-${qt_ver}" --strip-components 1
  touch "/usr/src/qttools-${qt_ver}/.unpack_ok"
fi
cd "/usr/src/qttools-${qt_ver}"
rm -fr CMakeCache.txt
"${QT_BASE_DIR}/bin/qt-configure-module" .
cmake --build . --parallel
cmake --install .

# build latest boost
boost_ver="$(retry curl -ksSfL --compressed https://www.boost.org/users/download/ \| grep "'>Version\s*'" \| sed -r "'s/.*Version\s*([^<]+).*/\1/'" \| head -1)"
echo "boost version ${boost_ver}"
mkdir -p "/usr/src/boost-${boost_ver}"
if [ ! -f "/usr/src/boost-${boost_ver}/.unpack_ok" ]; then
  boost_latest_url="https://sourceforge.net/projects/boost/files/boost/${boost_ver}/boost_${boost_ver//./_}.tar.bz2/download"
  retry curl -kSL "${boost_latest_url}" \| tar -jxf - -C "/usr/src/boost-${boost_ver}" --strip-components 1
  touch "/usr/src/boost-${boost_ver}/.unpack_ok"
fi
cd "/usr/src/boost-${boost_ver}"
if [ ! -f ./b2 ]; then
  ./bootstrap.sh
fi
./b2 -d0 -q install --with-system variant=release link=shared runtime-link=shared
cd "/usr/src/boost-${boost_ver}/tools/build"
if [ ! -f ./b2 ]; then
  ./bootstrap.sh
fi
./b2 -d0 -q install variant=release link=shared runtime-link=shared

# build libtorrent-rasterbar
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
cmake \
  -B build \
  -G "Ninja" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17
cmake --build build
cmake --install build
# force refresh ld.so.cache
ldconfig

# build qbittorrent
cd "${SELF_DIR}/../../"
rm -fr build/CMakeCache.txt
cmake \
  -B build \
  -G "Ninja" \
  -DQT6=ON \
  -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
  -DCMAKE_BUILD_TYPE="Release" \
  -DCMAKE_CXX_STANDARD="17" \
  -DCMAKE_INSTALL_PREFIX="/tmp/qbee/AppDir/usr"
cmake --build build
rm -fr /tmp/qbee/
cmake --install build

# build AppImage
# linuxdeploy_download_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
# linuxdeploy_plugin_qt_download_url="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
# if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
#   linuxdeploy_download_url="https://ghproxy.com/${linuxdeploy_download_url}"
#   linuxdeploy_plugin_qt_download_url="https://ghproxy.com/${linuxdeploy_plugin_qt_download_url}"
# fi
# [ -x "/tmp/linuxdeploy-x86_64.AppImage" ] || retry curl -LC- -o /tmp/linuxdeploy-x86_64.AppImage "${linuxdeploy_download_url}"
# [ -x "/tmp/linuxdeploy-plugin-qt-x86_64.AppImage" ] || retry curl -LC- -o /tmp/linuxdeploy-plugin-qt-x86_64.AppImage "${linuxdeploy_plugin_qt_download_url}"
# chmod -v +x '/tmp/linuxdeploy-plugin-qt-x86_64.AppImage' '/tmp/linuxdeploy-x86_64.AppImage'
# cd "/tmp/qbee"
# mkdir -p "/tmp/qbee/AppDir/apprun-hooks/"
# echo 'export XDG_DATA_DIRS="${APPDIR:-"$(dirname "${BASH_SOURCE[0]}")/.."}/usr/share:${XDG_DATA_DIRS}:/usr/share:/usr/local/share"' >"/tmp/qbee/AppDir/apprun-hooks/xdg_data_dirs.sh"
# APPIMAGE_EXTRACT_AND_RUN=1 \
#   OUTPUT='qBittorrent-Enhanced-Edition.AppImage' \
#   UPDATE_INFORMATION="zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition.AppImage.zsync" \
#   EXTRA_QT_PLUGINS=tls \
#   /tmp/linuxdeploy-x86_64.AppImage --appdir="/tmp/qbee/AppDir" --output=appimage --plugin qt

linuxdeploy_qt_download_url="https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage"
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  linuxdeploy_qt_download_url="https://ghproxy.com/${linuxdeploy_qt_download_url}"
fi
[ -x "/tmp/linuxdeployqt-continuous-x86_64.AppImage" ] || retry curl -kSLC- -o /tmp/linuxdeployqt-continuous-x86_64.AppImage "${linuxdeploy_qt_download_url}"
chmod -v +x '/tmp/linuxdeployqt-continuous-x86_64.AppImage'
cd "/tmp/qbee"
ln -svf usr/share/icons/hicolor/scalable/apps/qbittorrent.svg /tmp/qbee/AppDir/
# this script is from linuxdeploy-plugin-qt: https://github.com/linuxdeploy/linuxdeploy-plugin-qt/blob/master/src/deployment.h#L98
cat >/tmp/qbee/AppDir/AppRun <<EOF
#!/bin/bash -e

this_dir="\$(readlink -f "\$(dirname "\$0")")"
if [ -z "\${QT_QPA_PLATFORMTHEME}" ]; then
  case "\${XDG_CURRENT_DESKTOP}" in
      *GNOME*|*gnome*|*XFCE*)
          export QT_QPA_PLATFORMTHEME=gtk3
          ;;
  esac
fi
export XDG_DATA_DIRS="\${this_dir}/usr/share:\${XDG_DATA_DIRS}:/usr/share:/usr/local/share"

exec "\${this_dir}/usr/bin/qbittorrent" "\$@"
EOF
chmod 755 -v /tmp/qbee/AppDir/AppRun
APPIMAGE_EXTRACT_AND_RUN=1 \
  /tmp/linuxdeployqt-continuous-x86_64.AppImage \
  /tmp/qbee/AppDir/usr/share/applications/*.desktop \
  -always-overwrite \
  -appimage \
  -no-copy-copyright-files \
  -updateinformation="zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition.AppImage.zsync" \
  -extra-plugins=iconengines,imageformats,platforminputcontexts,platforms/libqxcb.so,platformthemes,sqldrivers,tls

cp -fv /tmp/qbee/qBittorrent-x86_64.AppImage "${SELF_DIR}/qBittorrent-Enhanced-Edition.AppImage"
cp -fv /tmp/qbee/qBittorrent-x86_64.AppImage.zsync "${SELF_DIR}/qBittorrent-Enhanced-Edition.AppImage.zsync"
