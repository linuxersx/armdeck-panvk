#!/usr/bin/env bash
# 为 MT6785 / Mali-G76（Bifrost）构建 Linux/Wayland 版 PanVK ICD。
#
# 来源：
#   - Mesa 27.0.0-devel（只恢复 src/loader 与 include/vulkan）
#   - JimVulkan/mali-panvk（固定 commit 58f2c55854）
#
# 运行环境：aarch64 Arch Linux ARM，需网络和 Mesa 构建依赖（见 README）。
# 产物：$OUT/libvulkan_panfrost.so + panfrost_icd.aarch64.json
set -euo pipefail

PANVK_REPO="${PANVK_REPO:-JimVulkan/mali-panvk}"
PANVK_COMMIT="${PANVK_COMMIT:-58f2c55854}"
MESA_URL="${MESA_URL:-https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.tar.gz}"
SRC="${SRC:-/work/mali-panvk}"
BUILD="${BUILD:-$SRC/build-linux}"
OUT="${OUT:-/out/armdeck-panvk}"
CACHE="${CACHE:-/work}"

mkdir -p "$CACHE" "$OUT"

# --- 1. 获取固定 commit 的源码 ----------------------------------------------
# 用 codeload tar.gz 而不是 git clone：上游 clone 偶发 HTTP/2 错误，
# 而且固定 commit 后构建可重复。
if [ ! -d "$SRC/src/panfrost" ]; then
    tarball="$CACHE/mali-panvk-$PANVK_COMMIT.tar.gz"
    if [ ! -s "$tarball" ]; then
        echo ">> 下载 $PANVK_REPO@$PANVK_COMMIT"
        curl -4 -fL --retry 3 --max-time 1800 -o "$tarball.part" \
            "https://codeload.github.com/$PANVK_REPO/tar.gz/$PANVK_COMMIT"
        mv "$tarball.part" "$tarball"
    fi
    TMP="$(mktemp -d)"
    tar -xzf "$tarball" -C "$TMP"
    rm -rf "$SRC"
    mv "$TMP"/mali-panvk-* "$SRC"
    rm -rf "$TMP"
fi
cd "$SRC"

# --- 2. 恢复 fork 裁掉的 Linux 构建部分 --------------------------------------
if [ ! -f "$SRC/.armdeck-linux-patched" ]; then
    mesa="$CACHE/mesa-main.tar.gz"
    if [ ! -s "$mesa" ]; then
        echo ">> 下载 Mesa main（只取 src/loader 与 include/vulkan）"
        curl -4 -fL --retry 3 --max-time 1800 -o "$mesa.part" "$MESA_URL"
        mv "$mesa.part" "$mesa"
    fi
    TMP="$(mktemp -d)"
    tar -xzf "$mesa" -C "$TMP" mesa-main/src/loader mesa-main/include/vulkan

    if [ ! -d src/loader ]; then
        cp -a "$TMP/mesa-main/src/loader" src/
    fi
    for f in "$TMP"/mesa-main/include/vulkan/*; do
        b="$(basename "$f")"
        [ -e "include/vulkan/$b" ] || cp -a "$f" "include/vulkan/$b"
    done

    # Mesa main 把协议 key 改名为 linux-dmabuf-v1；该分支的 WSI 仍用旧名。
    python3 - <<'PY'
p = "src/loader/meson.build"
s = open(p).read()
if "linux-dmabuf-unstable-v1" not in s:
    anchor = """  foreach name, xml : wp_protos
    wp_files += {name : mod_wl.scan_xml(xml, include_core_only : false)}
  endforeach"""
    add = anchor + """
  # Mesa main 改了名字；本树的 panvk WSI 仍引用旧 key。
  wp_files += {'linux-dmabuf-unstable-v1' : wp_files['linux-dmabuf-v1']}"""
    assert anchor in s, "loader meson 锚点未找到"
    open(p, "w").write(s.replace(anchor, add))
PY
    sed -i 's/linux-dmabuf-unstable-v1-client-protocol\.h/linux-dmabuf-v1-client-protocol.h/g' \
        src/vulkan/wsi/wsi_common_wayland.c

    rm -rf "$TMP"
    touch "$SRC/.armdeck-linux-patched"
fi

# --- 3. Bifrost / Wayland WSI 修复 -------------------------------------------
# 幂等：每处都先检查 marker，重复执行不会重复修改。
python3 - <<'PY'
def patch(path, old, new, marker):
    s = open(path).read()
    if marker in s:
        return
    assert old in s, f"{path} 锚点未找到"
    open(path, "w").write(s.replace(old, new))
    print(f"patched {path}")

# 3.1 合成器没有 linux-dmabuf 时允许 wl_shm 回退。
patch(
    "src/panfrost/vulkan/panvk_wsi.c",
    "   physical_device->wsi_device.supports_modifiers = true;",
    "   /* 合成器没有 linux-dmabuf 时允许 wl_shm 回退。 */\n"
    "   physical_device->wsi_device.wl_sw_fallback = true;\n"
    "   /* Bifrost：fork 暴露的部分显式 modifier 会被 panvk_image_can_use_mod()\n"
    "    * 拒绝，先只走线性。 */\n"
    "   physical_device->wsi_device.supports_modifiers = false;",
    "wl_sw_fallback = true",
)

# 3.2 fork 用内部 dummy resource 替代 null descriptor，但这三处仍保留
#     Bifrost 断言；gamescope 会调 textureSize，从而 abort。
p = "src/panfrost/vulkan/panvk_vX_nir_lower_descriptors.c"
s = open(p).read()
old = ("   /* TODO/Bifrost: Null descriptors */\n"
       "   assert(PAN_ARCH < 9 && !ctx->null_descriptor_support);\n")
new = ("   /* Bifrost 的 null descriptor 已用内部 dummy resource 替代（见\n"
       "    * panvk_device.h null_descs），这里 size/levels/samples 是有效的。 */\n")
if "dummy resource" not in s:
    assert s.count(old) == 3
    open(p, "w").write(s.replace(old, new))
    print(f"patched {p}")
PY

# --- 4. 构建 ----------------------------------------------------------------
if [ -d "$BUILD" ]; then
    echo ">> 复用 $BUILD（要重新配置请先删除）"
else
    echo ">> meson setup"
    meson setup "$BUILD" \
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
