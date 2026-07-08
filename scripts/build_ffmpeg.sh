#!/usr/bin/env bash
# build_ffmpeg.sh — Build FFmpeg xcframeworks for iOS + macOS
#
# Usage:
#   ./scripts/build_ffmpeg.sh               # build with default FFMPEG_VERSION
#   FFMPEG_VERSION=7.1 ./scripts/build_ffmpeg.sh
#
# Output: Sources/CFFmpeg/xcframeworks/*.xcframework
#         Sources/CFFmpeg/include/   (headers)
#
# Requirements:
#   brew install nasm pkg-config

set -eo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
MIN_IOS="${MIN_IOS:-17.0}"
MIN_TVOS="${MIN_TVOS:-17.0}"
MIN_MACOS="${MIN_MACOS:-14.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PACKAGE_DIR/Sources/CFFmpeg"
BUILD_DIR="${TMPDIR:-/tmp}/ffmpeg-build-$$"
SRC_DIR="$BUILD_DIR/src"

XCFW_DIR="$OUTPUT_DIR/xcframeworks"
HEADERS_DIR="$OUTPUT_DIR/include"

TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.gz"
TARBALL_URL="https://ffmpeg.org/releases/${TARBALL}"
# Optional cache dir so repeated runs don't re-download (e.g. CACHE_DIR=~/Downloads)
CACHE_DIR="${CACHE_DIR:-}"

# ── codec/format selection ─────────────────────────────────────────────────
# Only enable what the NativeBackend actually needs; keeps binary small.
CODEC_FLAGS=(
  --disable-everything
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-avdevice
  --disable-avfilter

  # Muxers / encoders — not needed
  --disable-muxers
  --disable-encoders

  # Video: hardware path via VideoToolbox; keep minimal SW decoder for thumbnails
  --enable-decoder=h264
  --enable-decoder=hevc
  --enable-decoder=av1
  --enable-decoder=vp9
  --enable-decoder=vp8
  --enable-decoder=mjpeg
  --enable-parser=h264
  --enable-parser=hevc
  --enable-parser=av1
  --enable-parser=vp9
  --enable-parser=vp8
  --enable-parser=mjpeg
  --enable-bsf=h264_mp4toannexb
  --enable-bsf=hevc_mp4toannexb

  # Audio decoders
  --enable-decoder=aac
  --enable-decoder=aac_latm
  --enable-decoder=mp3
  --enable-decoder=mp3float
  --enable-decoder=ac3
  --enable-decoder=eac3
  --enable-decoder=truehd
  --enable-decoder=alac
  --enable-decoder=flac
  --enable-decoder=opus
  --enable-decoder=vorbis
  --enable-decoder=dca
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_s32le
  --enable-decoder=pcm_f32le
  --enable-decoder=cook            # RealAudio Cooker (RMVB audio)
  --enable-parser=aac
  --enable-parser=aac_latm
  --enable-parser=ac3
  --enable-parser=mpegaudio

  # Legacy video decoders — RealVideo (RMVB), MPEG-4 ASP (DivX/Xvid), MPEG-2.
  # Software-only, but cheap to enable and covers a long tail of old media.
  --enable-decoder=rv10
  --enable-decoder=rv20
  --enable-decoder=rv30
  --enable-decoder=rv40
  --enable-decoder=mpeg4
  --enable-decoder=mpeg2video

  # Demuxers
  --enable-demuxer=mov        # mp4/m4v/mov
  --enable-demuxer=matroska   # mkv/webm
  --enable-demuxer=mpegts
  --enable-demuxer=hls
  --enable-demuxer=flv
  --enable-demuxer=avi
  --enable-demuxer=ogg
  --enable-demuxer=wav
  --enable-demuxer=mp3
  --enable-demuxer=flac
  --enable-demuxer=aac
  --enable-demuxer=rm         # RealMedia (.rm/.rmvb)
  --enable-demuxer=mpegps     # MPEG-PS (.vob/.mpg/.mpeg)

  # Network protocols
  --enable-protocol=file
  --enable-protocol=http
  --enable-protocol=https
  --enable-protocol=tcp
  --enable-protocol=tls
  --enable-protocol=crypto
  --enable-protocol=data

  # VideoToolbox hardware
  --enable-videotoolbox

  # Required libs
  --enable-swresample
  --enable-swscale
)

# ── helpers ────────────────────────────────────────────────────────────────

log() { echo "▶ $*"; }

check_deps() {
  for cmd in nasm pkg-config clang; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd  (brew install nasm pkg-config)"; exit 1; }
  done
}

download_src() {
  mkdir -p "$SRC_DIR"
  local tarball_path="$BUILD_DIR/$TARBALL"

  # Use cache dir if set, so repeated runs skip the download
  if [[ -n "$CACHE_DIR" && -f "$CACHE_DIR/$TARBALL" ]]; then
    log "Using cached tarball: $CACHE_DIR/$TARBALL"
    tarball_path="$CACHE_DIR/$TARBALL"
  else
    if [[ ! -f "$tarball_path" ]]; then
      log "Downloading FFmpeg ${FFMPEG_VERSION}..."
      curl -fL --progress-bar "$TARBALL_URL" -o "$tarball_path"
      # Copy to cache if requested
      if [[ -n "$CACHE_DIR" ]]; then
        mkdir -p "$CACHE_DIR"
        cp "$tarball_path" "$CACHE_DIR/$TARBALL"
      fi
    fi
  fi

  log "Extracting..."
  tar -xf "$tarball_path" -C "$SRC_DIR" --strip-components=1
}

# build_for <sdk> <arch> <extra_flags...>
build_for() {
  local sdk="$1"; local arch="$2"; shift 2
  local extra_flags=("$@")
  local prefix="$BUILD_DIR/install/${sdk}-${arch}"

  log "Building ${sdk}-${arch}..."

  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  local cc cxx
  cc="$(xcrun --sdk "$sdk" --find clang)"
  cxx="$(xcrun --sdk "$sdk" --find clang++)"

  local base_cflags="-arch ${arch} -isysroot ${sysroot}"
  local base_ldflags="-arch ${arch} -isysroot ${sysroot}"

  case "$sdk" in
    iphoneos)
      base_cflags+=" -mios-version-min=${MIN_IOS}"
      base_ldflags+=" -mios-version-min=${MIN_IOS}" ;;
    iphonesimulator)
      base_cflags+=" -mios-simulator-version-min=${MIN_IOS}"
      base_ldflags+=" -mios-simulator-version-min=${MIN_IOS}" ;;
    appletvos)
      base_cflags+=" -mtvos-version-min=${MIN_TVOS}"
      base_ldflags+=" -mtvos-version-min=${MIN_TVOS}" ;;
    appletvsimulator)
      base_cflags+=" -mtvos-simulator-version-min=${MIN_TVOS}"
      base_ldflags+=" -mtvos-simulator-version-min=${MIN_TVOS}" ;;
    macosx)
      base_cflags+=" -mmacosx-version-min=${MIN_MACOS}"
      base_ldflags+=" -mmacosx-version-min=${MIN_MACOS}" ;;
  esac

  mkdir -p "$prefix"
  (
    cd "$SRC_DIR"
    ./configure \
      --prefix="$prefix" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch="$arch" \
      --cc="$cc" \
      --cxx="$cxx" \
      --as="$cc" \
      --sysroot="$sysroot" \
      --extra-cflags="$base_cflags" \
      --extra-cxxflags="$base_cflags" \
      --extra-ldflags="$base_ldflags" \
      --disable-shared \
      --enable-static \
      --enable-nonfree \
      "${CODEC_FLAGS[@]}" \
      "${extra_flags[@]}"

    make -j"$(sysctl -n hw.logicalcpu)"
    make install
    # Clean between builds to avoid cross-arch contamination
    make distclean
  )
}

# lipo multiple arch static libs into one fat lib
lipo_libs() {
  local out_dir="$1"; shift
  local in_dirs=("$@")

  mkdir -p "$out_dir/lib" "$out_dir/include"
  cp -r "${in_dirs[0]}/include/." "$out_dir/include/"

  for lib in "${in_dirs[0]}"/lib/*.a; do
    local name
    name="$(basename "$lib")"
    local inputs=()
    for d in "${in_dirs[@]}"; do
      [[ -f "$d/lib/$name" ]] && inputs+=("$d/lib/$name")
    done
    if [[ ${#inputs[@]} -eq 1 ]]; then
      cp "${inputs[0]}" "$out_dir/lib/$name"
    else
      lipo -create "${inputs[@]}" -output "$out_dir/lib/$name"
    fi
  done
}

# make_xcframework <lib_name> <slice_dir> [<slice_dir2> ...]
# Each slice_dir must contain lib/<lib_name>.a and include/
make_xcframework() {
  local lib_name="$1"; shift
  local slice_dirs=("$@")
  local xcfw="$XCFW_DIR/${lib_name}.xcframework"

  local args=()
  for d in "${slice_dirs[@]}"; do
    args+=(-library "$d/lib/${lib_name}.a")
  done

  rm -rf "$xcfw"
  xcodebuild -create-xcframework "${args[@]}" -output "$xcfw"
  log "Created ${lib_name}.xcframework"
}

# ── main ───────────────────────────────────────────────────────────────────

main() {
  check_deps

  log "FFmpeg ${FFMPEG_VERSION} → ${XCFW_DIR}"
  mkdir -p "$BUILD_DIR" "$XCFW_DIR" "$HEADERS_DIR"

  download_src

  # ── compile each slice ─────────────────────────────────────────────────
  build_for iphoneos          arm64   --enable-neon
  build_for iphonesimulator   arm64   --enable-neon
  build_for iphonesimulator   x86_64
  build_for appletvos         arm64   --enable-neon
  build_for appletvsimulator  arm64   --enable-neon
  build_for appletvsimulator  x86_64
  build_for macosx            arm64   --enable-neon
  build_for macosx            x86_64

  # ── lipo iOS simulators ────────────────────────────────────────────────
  local ios_sim_fat="$BUILD_DIR/install/iphonesimulator-fat"
  lipo_libs "$ios_sim_fat" \
    "$BUILD_DIR/install/iphonesimulator-arm64" \
    "$BUILD_DIR/install/iphonesimulator-x86_64"

  # ── lipo tvOS simulators ───────────────────────────────────────────────
  local tvos_sim_fat="$BUILD_DIR/install/appletvsimulator-fat"
  lipo_libs "$tvos_sim_fat" \
    "$BUILD_DIR/install/appletvsimulator-arm64" \
    "$BUILD_DIR/install/appletvsimulator-x86_64"

  # ── lipo macOS ────────────────────────────────────────────────────────
  local mac_fat="$BUILD_DIR/install/macosx-fat"
  lipo_libs "$mac_fat" \
    "$BUILD_DIR/install/macosx-arm64" \
    "$BUILD_DIR/install/macosx-x86_64"

  # ── copy headers ────────────────────────────────────────────────────────
  log "Copying headers..."
  rm -rf "$HEADERS_DIR"
  cp -r "$BUILD_DIR/install/iphoneos-arm64/include/." "$HEADERS_DIR/"

  # Remove headers that reference Windows/Linux APIs not available on Apple platforms.
  # Keeping these causes Clang dependency scanner failures on iOS/macOS builds.
  rm -f \
    "$HEADERS_DIR/libavcodec/d3d11va.h" \
    "$HEADERS_DIR/libavcodec/dxva2.h" \
    "$HEADERS_DIR/libavcodec/qsv.h" \
    "$HEADERS_DIR/libavutil/hwcontext_d3d11va.h" \
    "$HEADERS_DIR/libavutil/hwcontext_d3d12va.h" \
    "$HEADERS_DIR/libavutil/hwcontext_dxva2.h" \
    "$HEADERS_DIR/libavutil/hwcontext_vaapi.h" \
    "$HEADERS_DIR/libavutil/hwcontext_vdpau.h" \
    "$HEADERS_DIR/libavutil/hwcontext_drm.h" \
    "$HEADERS_DIR/libavutil/hwcontext_oh.h" \
    "$HEADERS_DIR/libavutil/hwcontext_cuda.h" \
    "$HEADERS_DIR/libavutil/hwcontext_qsv.h" \
    "$HEADERS_DIR/libavutil/hwcontext_vulkan.h" \
    "$HEADERS_DIR/libavutil/hwcontext_opencl.h" \
    "$HEADERS_DIR/libavutil/hwcontext_amf.h" \
    "$HEADERS_DIR/libavcodec/vdpau.h"
  log "Stripped Windows/Linux-only headers"

  # ── create xcframeworks ─────────────────────────────────────────────────
  log "Creating xcframeworks..."
  local LIBS=(libavcodec libavformat libavutil libswresample libswscale)

  for lib in "${LIBS[@]}"; do
    make_xcframework "$lib" \
      "$BUILD_DIR/install/iphoneos-arm64" \
      "$ios_sim_fat" \
      "$BUILD_DIR/install/appletvos-arm64" \
      "$tvos_sim_fat" \
      "$mac_fat"
  done

  # Cleanup build dir (comment out to keep for debugging)
  rm -rf "$BUILD_DIR"

  log "Done. Xcframeworks in: $XCFW_DIR"
  log "Headers in:           $HEADERS_DIR"

  # ── optional: zip + checksum for GitHub Release ─────────────────────────
  # Run with RELEASE=1 to produce zips ready for uploading:
  #   RELEASE=1 CACHE_DIR=~/Downloads ./scripts/build_ffmpeg.sh
  if [[ "${RELEASE:-}" == "1" ]]; then
    package_for_release
  else
    echo ""
    echo "Tip: run with RELEASE=1 to also zip xcframeworks for GitHub Release upload."
  fi
}

package_for_release() {
  local zip_dir="$PACKAGE_DIR/release-zips"
  mkdir -p "$zip_dir"
  rm -f "$zip_dir"/*.zip "$zip_dir"/checksums.txt

  log "Packaging xcframeworks for GitHub Release..."

  local LIBS=(libavcodec libavformat libavutil libswresample libswscale)
  for lib in "${LIBS[@]}"; do
    local xcfw="$XCFW_DIR/${lib}.xcframework"
    local zip_path="$zip_dir/${lib}.xcframework.zip"
    log "  Zipping ${lib}..."
    (cd "$XCFW_DIR" && zip -qr "$zip_path" "${lib}.xcframework")
    local checksum
    checksum=$(swift package compute-checksum "$zip_path" 2>/dev/null \
               || shasum -a 256 "$zip_path" | awk '{print $1}')
    echo "${lib}: ${checksum}" >> "$zip_dir/checksums.txt"
    echo "  checksum: ${checksum}"
  done

  echo ""
  log "Zips in:     $zip_dir"
  log "Checksums:   $zip_dir/checksums.txt"
  echo ""
  echo "── Next steps ──────────────────────────────────────────────────────"
  echo "1. Create a GitHub Release with tag: ffmpeg-${FFMPEG_VERSION}"
  echo "2. Upload all *.zip files from: $zip_dir"
  echo "3. Update Package.swift binaryTarget entries with the download URLs"
  echo "   and checksums from: $zip_dir/checksums.txt"
  echo "────────────────────────────────────────────────────────────────────"
}

main "$@"
