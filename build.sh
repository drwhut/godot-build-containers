#!/bin/bash
set -e

podman=`which podman || true`

if [ -z $podman ]; then
  echo "podman needs to be in PATH for this script to work."
  exit 1
fi

if [ -z "$1" -o -z "$2" -o -z "$3" ]; then
  echo "Usage: $0 <godot branch> <base distro> <mono version>"
  echo
  echo "Example: $0 3.x f35 mono-6.12.0.178"
  echo
  echo "godot branch:"
  echo "        Informational, tracks the Godot branch these containers are intended for."
  echo
  echo "base distro:"
  echo "        Informational, tracks the base Linux distro these containers are based on."
  echo
  echo "mono version:"
  echo "	Defines the Mono tag that will be cloned with Git to compile from source."
  echo
  echo "The resulting image version will be <godot branch>-<base distro>-<mono version>."
  exit 1
fi

godot_branch=$1
base_distro=$2
mono_version=$3
img_version=$godot_branch-$base_distro-$mono_version
files_root=$(pwd)/files
mono_root="${files_root}/${mono_version}"
build_msvc=0

# Confirm settings
echo "Docker image tag: ${img_version}"
echo "Mono branch: ${mono_version}"
if [ -e ${mono_root} ]; then
  mono_exists="(exists)"
fi
echo "Mono source folder: ${mono_root} ${mono_exists}"
echo
while true; do
  read -p "Is this correct? [y/n] " yn
  case $yn in
    [Yy]* ) break;;
    [Nn]* ) exit 1;;
    * ) echo "Please answer yes or no.";;
  esac
done

mkdir -p logs

# Check out and patch Mono version
if [ ! -e ${mono_root} ]; then
  git clone -b ${mono_version} --single-branch --progress --depth 1 https://github.com/mono/mono ${mono_root}
  pushd ${mono_root}
  # Download all submodules, up to 6 at a time
  git submodule update --init --recursive --recommend-shallow -j 6 --progress
  # Set up godot-mono-builds in tree
  git clone --progress https://github.com/godotengine/godot-mono-builds
  pushd godot-mono-builds
  git checkout 4bf530983a52d09f4f63aea032aee9be47931cbd
  export MONO_SOURCE_ROOT=${mono_root}
  python3 patch_mono.py
  popd
  popd
fi

# You can add --no-cache  as an option to podman_build below to rebuild all containers from scratch
export podman_build="$podman build --build-arg img_version=${img_version}"
export podman_build_mono="$podman_build --build-arg mono_version=${mono_version} -v ${files_root}:/root/files"

$podman build -v ${files_root}:/root/files -t godot-fedora:${img_version} -f Dockerfile.base . 2>&1 | tee logs/base.log
$podman_build -t godot-export:${img_version} -f Dockerfile.export . 2>&1 | tee logs/export.log

$podman_build_mono -t godot-mono:${img_version} -f Dockerfile.mono . 2>&1 | tee logs/mono.log
$podman_build_mono -t godot-mono-glue:${img_version} -f Dockerfile.mono-glue . 2>&1 | tee logs/mono-glue.log
$podman_build_mono -t godot-linux:${img_version} -f Dockerfile.linux . 2>&1 | tee logs/linux.log
$podman_build_mono -t godot-windows:${img_version} -f Dockerfile.windows . 2>&1 | tee logs/windows.log

XCODE_SDK=13.3.1
OSX_SDK=12.3
IOS_SDK=15.4
if [ ! -e files/MacOSX${OSX_SDK}.sdk.tar.xz ] || [ ! -e files/iPhoneOS${IOS_SDK}.sdk.tar.xz ] || [ ! -e files/iPhoneSimulator${IOS_SDK}.sdk.tar.xz ]; then
  if [ ! -e files/Xcode_${XCODE_SDK}.xip ]; then
    echo "files/Xcode_${XCODE_SDK}.xip is required. It can be downloaded from https://developer.apple.com/download/more/ with a valid apple ID."
    exit 1
  fi

  echo "Building OSX and iOS SDK packages. This will take a while"
  $podman_build -t godot-xcode-packer:${img_version} -f Dockerfile.xcode -v ${files_root}:/root/files . 2>&1 | tee logs/xcode.log
  $podman run -it --rm -v ${files_root}:/root/files -e XCODE_SDKV="${XCODE_SDK}" -e OSX_SDKV="${OSX_SDK}" -e IOS_SDKV="${IOS_SDK}" godot-xcode-packer:${img_version} 2>&1 | tee logs/xcode_packer.log
fi

$podman_build_mono -t godot-osx:${img_version} -f Dockerfile.osx . 2>&1 | tee logs/osx.log
