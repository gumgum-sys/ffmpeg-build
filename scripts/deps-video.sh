#!/usr/bin/env bash
# dav1d + libvpx static PIC for MSE software fallback.
# Sourced from build-ios / build-android / build-desktop after common.sh.
#
#   fetch_video_srcs
#   build_dav1d  "$DEPS" "$CC" "$CFLAGS" "$AR"
#   build_libvpx "$DEPS" "$CC" "$CFLAGS" "$AR"
#
# Pinned tarballs (BSD). Not GPL. ffmpeg --enable-libdav1d / --enable-libvpx.
set -euo pipefail

DAV1D_VER="${DAV1D_VER:-1.5.1}"
LIBVPX_VER="${LIBVPX_VER:-1.15.2}"
DAV1D_URL="https://github.com/videolan/dav1d/archive/refs/tags/${DAV1D_VER}.tar.gz"
LIBVPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${LIBVPX_VER}.tar.gz"

fetch_tarball() {
  local url="$1" dest="$2" stamp="$3"
  if [ -f "$dest/$stamp" ]; then
    return 0
  fi
  local tmp="$ROOT/.cache"
  mkdir -p "$tmp"
  local tgz="$tmp/$(basename "$url")"
  echo "[deps] fetch $url"
  curl -fsSL -o "$tgz" "$url"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
  touch "$dest/$stamp"
}

fetch_video_srcs() {
  mkdir -p "$SRC"
  fetch_tarball "$DAV1D_URL" "$SRC/dav1d" ".ver-$DAV1D_VER"
  fetch_tarball "$LIBVPX_URL" "$SRC/libvpx" ".ver-$LIBVPX_VER"
}

ensure_meson() {
  command -v meson >/dev/null && command -v ninja >/dev/null && return 0
  if command -v brew >/dev/null; then
    echo "[deps] brew install meson ninja"
    brew install meson ninja
    return 0
  fi
  echo "meson+ninja required to build dav1d" >&2
  return 1
}

# C-only dav1d (no asm): portable across iOS sim/device, Android, and desktop.
build_dav1d() {
  local prefix="$1" cc="$2" cflags="$3" ar="$4"
  [ -f "$prefix/lib/libdav1d.a" ] && return 0
  ensure_meson
  local bdir="$prefix/.build/dav1d"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  echo "[deps] dav1d $DAV1D_VER -> $prefix"
  if [ "${VIDEO_MESON_CROSS:-}" = 1 ]; then
    CC="$cc" AR="$ar" CFLAGS="$cflags" \
      MESON_SYS="${VIDEO_MESON_SYSTEM:-darwin}" MESON_CPU="${VIDEO_MESON_CPU:-aarch64}" \
      python3 - "$bdir/cross.ini" <<'PY'
import os, shlex, sys
args = ", ".join("'" + t.replace("'", "\\'") + "'" for t in shlex.split(os.environ["CFLAGS"]))
open(sys.argv[1], "w").write(f"""[binaries]
c = '{os.environ["CC"]}'
ar = '{os.environ["AR"]}'
[built-in options]
c_args = [{args}]
c_link_args = [{args}]
[host_machine]
system = '{os.environ["MESON_SYS"]}'
cpu_family = '{os.environ["MESON_CPU"]}'
cpu = '{os.environ["MESON_CPU"]}'
endian = 'little'
""")
PY
    meson setup "$bdir" "$SRC/dav1d" \
      --prefix="$prefix" --libdir=lib --buildtype=release --default-library=static \
      -Denable_tools=false -Denable_tests=false -Denable_examples=false \
      -Denable_asm=false \
      --cross-file "$bdir/cross.ini"
  else
    env CC="$cc" AR="$ar" meson setup "$bdir" "$SRC/dav1d" \
      --prefix="$prefix" --libdir=lib --buildtype=release --default-library=static \
      -Denable_tools=false -Denable_tests=false -Denable_examples=false \
      -Denable_asm=false \
      -Dc_args="$cflags"
  fi
  meson compile -C "$bdir" -j "$JOBS"
  meson install -C "$bdir"
}

build_libvpx() {
  local prefix="$1" cc="$2" cflags="$3" ar="$4"
  [ -f "$prefix/lib/libvpx.a" ] && return 0
  local bdir="$prefix/.build/libvpx"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  echo "[deps] libvpx $LIBVPX_VER -> $prefix"
  (
    cd "$bdir"
    # generic-gnu + clang flags: no hand-written asm, PIC, decode-only.
    CC="$cc" CXX="$cc" AR="$ar" RANLIB="${RANLIB:-ranlib}" \
      CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$cflags" \
      "$SRC/libvpx/configure" \
        --prefix="$prefix" --libdir="$prefix/lib" \
        --target=generic-gnu \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-static --disable-shared --enable-pic \
        --enable-vp8 --enable-vp9 \
        --disable-vp8-encoder --disable-vp9-encoder \
        --disable-runtime-cpu-detect \
        --extra-cflags="$cflags"
    make -j"$JOBS"
    make install
  )
}

# ffmpeg configure extras once dav1d+vpx are in $DEPS.
video_sw_ff_opts() {
  echo "--enable-libdav1d --enable-libvpx --enable-decoder=libdav1d,libvpx-vp9,av1"
}

video_vpx_only_ff_opts() {
  echo "--enable-libvpx --enable-decoder=libvpx-vp9"
}
