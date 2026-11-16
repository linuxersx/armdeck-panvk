#!/usr/bin/env bash
# 构建仓库内的 PanVK 源码（已包含 Linux/Wayland 修复）。
#
# 运行环境：aarch64 Arch Linux ARM，依赖见 README。
# 产物：$OUT/libvulkan_panfrost.so + panfrost_icd.aarch64.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$ROOT}"
BUILD="${BUILD:-$SRC/build-linux}"
OUT="${OUT:-$SRC/out}"

# 确认这是打好 Linux/Wayland 补丁的树，而不是上游原始源码。
[ -f "$SRC/src/loader/meson.build" ] || {
    echo "缺少 src/loader；请使用本仓库的完整源码树" >&2
    exit 1
}
grep -q "wl_sw_fallback = true" "$SRC/src/panfrost/vulkan/panvk_wsi.c" || {
    echo "缺少 wl_sw_fallback 修复；请使用本仓库的完整源码树" >&2
    exit 1
}

if [ -d "$BUILD" ]; then
    echo ">> 复用 $BUILD（要重新配置请先删除）"
else
    echo ">> meson setup"
    meson setup "$BUILD" "$SRC" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dmesa-clc=enabled \
        -Dprecomp-compiler=enabled \
        -Dvulkan-drivers=panfrost \
        -Dgallium-drivers= \
        -Dplatforms=wayland \
        -Dllvm=enabled \
        -Dshared-llvm=enabled \
        -Dgles1=disabled \
        -Dgles2=disabled \
        -Degl=disabled \
        -Dglx=disabled \
        -Dgbm=disabled \
        -Dtools= \
        -Dvideo-codecs=
fi

echo ">> ninja"
ninja -C "$BUILD"

mkdir -p "$OUT"
cp -f "$BUILD/src/panfrost/vulkan/libvulkan_panfrost.so" "$OUT/"
cat > "$OUT/panfrost_icd.aarch64.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/usr/lib/libvulkan_panfrost.so",
        "api_version": "1.4.0"
    }
}
EOF

echo ">> 产物："
ls -lh "$OUT"
