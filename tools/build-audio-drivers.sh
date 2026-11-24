#!/bin/zsh
# Builds the fork's audio drivers from BlackHole (GPL-3.0, like this repo):
# one output and one input device per receiver, named "<name> (OpenDisplay)".
#   OD<Name>Out: visible output; the sender reads its hidden input mirror and
#                forwards the sound to that receiver.
#   OD<Name>In:  visible input; the sender writes that receiver's microphone
#                into its hidden output mirror.
# Usage:   tools/build-audio-drivers.sh "MacBook Air" "iPad"
# Install (admin password, restarts Core Audio for a second):
#   sudo cp -R build/audio-drivers/*.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
# The sender finds a receiver's devices by UID: OD<Name>Out_2_UID / OD<Name>In_2_UID
# with spaces removed from <Name>, matching the receiver's device kind.
set -e
cd "$(dirname "$0")/.."
OUT="$PWD/build/audio-drivers"
SRC="${TMPDIR:-/tmp}/opendisplay-blackhole"
[[ -d "$SRC" ]] || git clone -q --depth 1 https://github.com/ExistentialAudio/BlackHole.git "$SRC"
mkdir -p "$OUT"
(( $# )) || set -- "MacBook Air" "iPad"

build() {  # driver name, visible device name, device has input, device has output
  local driver=$1 label=${2// /\\ } in=$3 out=$4
  local bundle="com.kalebdev.opendisplay.audio.${driver:l}"
  local defs="kDriver_Name=\\\"$driver\\\" kPlugIn_BundleID=\\\"$bundle\\\" kHas_Driver_Name_Format=false"
  defs+=" kDevice_Name=\\\"$label\\\" kManufacturer_Name=\\\"OpenDisplay\\\""
  defs+=" kDevice_HasInput=$in kDevice_HasOutput=$out"
  defs+=" kDevice2_Name=\\\"$driver\\ Mirror\\\" kDevice2_IsHidden=true kDevice2_HasInput=$out kDevice2_HasOutput=$in"
  xcodebuild -quiet -project "$SRC/BlackHole.xcodeproj" -scheme BlackHole -configuration Release \
    -derivedDataPath "$SRC/build-$driver" PRODUCT_BUNDLE_IDENTIFIER="$bundle" PRODUCT_NAME="$driver" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    GCC_PREPROCESSOR_DEFINITIONS="\$GCC_PREPROCESSOR_DEFINITIONS $defs" build
  rm -rf "$OUT/$driver.driver"
  cp -R "$SRC/build-$driver/Build/Products/Release/$driver.driver" "$OUT/"
}

for name in "$@"; do
  slug=${name// /}
  build "OD${slug}Out" "$name (OpenDisplay)" false true
  build "OD${slug}In" "$name (OpenDisplay)" true false
done
ls -d "$OUT"/*.driver
