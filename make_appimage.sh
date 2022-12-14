#!/usr/bin/env bash
set -x #echo on
set -e #Exists on errors

#alias ll="ls -al"

SCRIPTPATH=$(cd $(dirname "$BASH_SOURCE") && pwd)
echo "SCRIPTPATH = $SCRIPTPATH"
pushd ${SCRIPTPATH}

export APP=GnuCash
export LOWERAPP=gnucash
export APPDIR="${SCRIPTPATH}/appdir"

#=== Define GnuCash version to build

# Workaround for build outside github: "env" file should then contain exports of github variables.
if [ -f "./env" ];
then
  source ./env
fi

if [ "$GITHUB_REF_NAME" = "" ];
then
	echo "Please define tag for this release (GITHUB_REF_NAME)"
	exit 1
fi

# Get App version from tag, excluding suffixe "-Revision" used only for specific AppImage builds...
export VERSION=$(echo $GITHUB_REF_NAME | cut -d'-' -f1)

#=== Package installations for building

sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes patchelf librsvg2-dev libxslt-dev xsltproc libboost-all-dev libgtk-3-dev guile-3.0-dev libgwengui-gtk3-dev libaqbanking-dev libofx-dev libdbi-dev libdbd-sqlite3 libwebkit2gtk-4.0-dev googletest swig language-pack-en language-pack-fr build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev libssl-dev libsqlite3-dev libreadline-dev libffi-dev curl libbz2-dev liblzma-dev

#=== Get App source

if [ ! -f "./${LOWERAPP}-${VERSION}.tar.gz" ];
then
  wget --continue "https://github.com/gnucash/gnucash/releases/download/${VERSION}/${LOWERAPP}-${VERSION}.tar.gz" --output-document="${LOWERAPP}-${VERSION}.tar.gz"
  rm --recursive --force "./${LOWERAPP}-${VERSION}"
fi

if [ ! -d "./${LOWERAPP}-${VERSION}" ];
then
  tar xf "./${LOWERAPP}-${VERSION}.tar.gz"
fi

#=== Compile main App

APP_BuildDir="${LOWERAPP}-${VERSION}_build"

if [ ! -d "${APP_BuildDir}" ];
then
  mkdir "${APP_BuildDir}"
  pushd "${APP_BuildDir}"

  cmake -DWITH_PYTHON=ON -DCMAKE_INSTALL_PREFIX=$APPDIR/usr "../${LOWERAPP}-${VERSION}/"
  make -j$(nproc)

  popd
fi

#=== Install main application into AppDir

if [ ! -d "${APPDIR}" ];
then
  mkdir --parents "${APPDIR}"

  pushd "${APP_BuildDir}"
  make install
  popd
fi

#=== Copy extra shared libraries

APP_DEPDIR="${SCRIPTPATH}/${LOWERAPP}-dependencies"

# Get dependencies packages for runtime (I couldn't use linuxdeploy as I wanted so this is workaround in order to use AppImageTool directly...)
if [ ! -d "${APP_DEPDIR}" ];
then
  echo "Downloading gnucash dependencies packages..."
  mkdir --parents "${APP_DEPDIR}"
  pushd "${APP_DEPDIR}"
  
	# Initial source = gnucash package description for ubuntu 20.04 LTS (https://packages.ubuntu.com/jammy/gnucash)
	# Multiple libraries added...
  apt-get download guile-3.0 guile-3.0-libs libaqbanking44 libboost-filesystem1.71.0 libboost-locale1.71.0 libboost-program-options1.71.0 libboost-regex1.71.0 libcairo2 libcrypt-ssleay-perl libdate-manip-perl libdbd-sqlite3 libdbi1 libfinance-quote-perl libjavascriptcoregtk-4.0-18 libgdk-pixbuf2.0-0 libgtk-3-0 libgwengui-gtk3-0 libgwenhywfar79 libharfbuzz-icu0 libhtml-tableextract-perl libhtml-tree-perl libicu66 libkeyutils1 libofx7 libpango-1.0-0  libpangoft2-1.0-0 libpangocairo-1.0-0 libpython3.8 libsecret-1-0 libwebkit2gtk-4.0-37 libwww-perl libxml2 perl zlib1g
  apt-get download libosp5 libffi7 libboost-thread1.71.0 libboost-date-time1.71.0 libnotify4 libjpeg-turbo8 libwebp6

  for f in $(ls *.deb); do dpkg-deb -x ./$f "${APP_DEPDIR}/appdir/"; done
  cp --recursive --remove-destination appdir/lib/   appdir/usr/ && rm --recursive appdir/lib
  cp --recursive --remove-destination appdir/lib64/ appdir/usr/ && rm --recursive appdir/lib64
 
	# Some missing elements:
	if [ ! -f "${APP_DEPDIR}/appdir/usr/bin/guile"];
	then
		pushd "${APP_DEPDIR}/appdir/usr/bin"
		ln --symbolic ../lib/x86_64-linux-gnu/guile-2.2/bin/guile
		popd
	fi
 
  popd
fi

echo "Copying dependent libraries..."
cp --preserve --recursive "${APP_DEPDIR}/appdir" "${SCRIPTPATH}"

#=== bundle python 3.8 build as well, as application would fail if the host has a later python version installed
Python_Build_Dir="${SCRIPTPATH}/python-build/"
Python_Version="3.8.2"
Python_Package_Name="Python-${Python_Version}"
Python_Package_Archive="${Python_Package_Name}.tar.xz"
Python_Cache_Dir="${Python_Build_Dir}/.cache"
Python_Interm_Install_Dir="${Python_Build_Dir}/install"

wget "https://www.python.org/ftp/python/${Python_Version}/${Python_Package_Archive}" -P "${Python_Build_Dir}"
tar xf "${Python_Build_Dir}/${Python_Package_Archive}" -C "${Python_Build_Dir}"

pushd "${Python_Build_Dir}/${Python_Package_Name}"

mkdir -p "${Python_Cache_Dir}"
mkdir -p "${Python_Interm_Install_Dir}"

./configure --cache-file="${Python_Cache_Dir}/python.config.cache" --prefix="${Python_Interm_Install_Dir}" --enable-ipv6 --enable-loadable-sqlite-extensions --enable-shared --without-ensurepip --enable-optimizations
make -s -j$(nproc)
make -s install

{
    printf '%s\0' "${Python_Interm_Install_Dir}/bin/python3.8"
    find "${Python_Interm_Install_Dir}" -type f -regex '.*\.so\(\.[0-9.]+\)?$' -print0
} | xargs -0 --no-run-if-empty --verbose -n1 strip

rsync -a --ignore-existing "${Python_Interm_Install_Dir}/" "${APPDIR}/usr"

popd

#=== Complete AppDir (useful here for execution tests directly from AppDir)

pushd ${APPDIR}

cp --preserve ${SCRIPTPATH}/AppRun .
chmod +x ./AppRun

if [ ! -f ./gnucash.desktop ];
then
  ln --symbolic ./usr/share/applications/gnucash.desktop ./gnucash.desktop
fi
if [ ! -f ./gnucash-icon.svg ];
then
  ln --symbolic ./usr/share/icons/hicolor/scalable/apps/gnucash-icon.svg ./gnucash-icon.svg
fi

popd

#=== Construct AppImage

#This tool is freezed with release to be able to reproduce AppImage if needed since this is a "continuous" tool.
if [ ! -f "./appimagetool-x86_64.AppImage" ];
then
	wget "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
	chmod a+x appimagetool-x86_64.AppImage
fi

ARCH=x86_64 ./appimagetool-x86_64.AppImage --appimage-extract-and-run --no-appstream --verbose "${APPDIR}"

#===

echo "AppImage generated = $(readlink -f $(ls ${APP}*.AppImage))"
popd
