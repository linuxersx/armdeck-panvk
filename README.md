# armdeck-panvk

面向 **MT6785 / Mali-G76（Bifrost）** 的 Linux / Wayland 版 PanVK Vulkan ICD。

仓库包含：

- 基于 Mesa 27.0.0-devel 与 [JimVulkan/mali-panvk](https://github.com/JimVulkan/mali-panvk)
  的**完整驱动源码树**（固定 commit `58f2c55854`）；
- 已应用的 Linux / Wayland WSI 与 Bifrost 修复；
- 可直接构建树内源码的构建脚本；
- Releases 中的预编译 `libvulkan_panfrost.so`。

驱动版本：

```text
Device:      PanVK-G76 MC4
apiVersion:  1.3.363
driverInfo:  Mesa 27.0.0-devel (git-58f2c55854)
```

## 来源

- **Mesa 27.0.0-devel**
  <https://gitlab.freedesktop.org/mesa/mesa>
  本仓库从 Mesa main 恢复了该 fork 裁掉的 `src/loader` 和
  `include/vulkan` WSI 头文件。

- **JimVulkan/mali-panvk**
  <https://github.com/JimVulkan/mali-panvk>
  固定 commit：`58f2c55854`。
  这是面向 Android / Arm kbase 的 Mali PanVK 分支，保留了 mainline
  `panfrost` / `panthor` kmod 后端。

上游 fork 自带的 README 保留为 [`README.upstream.md`](README.upstream.md)，
Android 构建脚本保留为 `build.sh`。

## 仓库结构

```text
README.md                    本文件
README.upstream.md           上游 fork 的 README
build-panvk-mali27.sh        Linux / Wayland 构建脚本
build.sh                     上游 Android 构建脚本（保留）
panfrost_icd.aarch64.json    Vulkan ICD 描述文件
meson.build                  源码树入口
src/                         完整 panvk / Mesa 源码
include/                     含恢复的 Vulkan WSI 头文件
src/loader/                  从 Mesa main 恢复的 loader
```

## 与上游的差异

源码树中已经应用以下修改，不需要在构建时再打补丁：

1. **恢复 Linux 构建需要的目录**
   - `src/loader`（Wayland WSI helper + libloader）
   - `include/vulkan/vulkan_*.h`（Wayland / display WSI 头文件）

2. **适配 Wayland protocol key**
   Mesa main 把 key 改名为 `linux-dmabuf-v1`，该分支的 WSI 仍引用旧名
   `linux-dmabuf-unstable-v1`。已在 `src/loader/meson.build` 中补上旧 key
   别名，并同步 `wsi_common_wayland.c` 的 include。

3. **`panvk_wsi.c`：`wl_sw_fallback = true`**
   合成器不暴露 `zwp_linux_dmabuf_v1` 时需要回退到 `wl_shm`，否则 surface
   query 返回 `VK_ERROR_SURFACE_LOST_KHR`。

4. **`panvk_wsi.c`：`supports_modifiers = false`**
   避免 WSI 传入的显式 DRM modifier 触发
   `panvk_image_get_explicit_mod()` 断言。客户端 WSI buffer 因此以线性布局
   导出（`DRM_FORMAT_MOD_INVALID`）。

5. **`panvk_vX_nir_lower_descriptors.c`：去掉 null descriptor 断言**
   该分支在 Bifrost 上用内部 dummy resource 替代 null descriptor，但
   `textureSize` / `textureLevels` / `textureSamples` 三处仍保留
   `TODO/Bifrost` 断言，调用这些路径的 Vulkan 应用会 abort。

## 构建

构建环境：**aarch64 Arch Linux ARM** 容器或机器。源码已在仓库内，
构建不需要联网。

依赖：

```sh
pacman -S --needed base-devel git meson ninja cmake pkgconf glslang \
  vulkan-headers wayland wayland-protocols libdrm libxkbcommon libinput \
  pixman luajit libdecor libx11 libxext libxfixes libxdamage libxcomposite \
  libxrender libxxf86vm libxtst libxi libxcursor libxmu libxres libxcb \
  xcb-util-wm xcb-util-errors xcb-util-renderutil xcb-util-image \
  xcb-util-keysyms seatd hwdata sdl2 pipewire vulkan-icd-loader \
  libdisplay-info xorg-xwayland libcap lcms2 python
```

> `lua` 建议用 `luajit`；Mesa 的 `mesa-clc` / `precomp-compiler` 需要
> `python-mako`、`python-packaging`、`python-yaml`，请一并安装。

构建：

```sh
./build-panvk-mali27.sh
```

脚本会直接在仓库根目录执行：

```text
meson setup build-linux \
  -Dvulkan-drivers=panfrost -Dplatforms=wayland ...
ninja -C build-linux
```

产物：

```text
build-linux/src/panfrost/vulkan/libvulkan_panfrost.so
out/libvulkan_panfrost.so
out/panfrost_icd.aarch64.json
```

可用环境变量：

```text
SRC     源码目录，默认仓库根目录
BUILD   构建目录，默认 $SRC/build-linux
OUT     产物目录，默认 $SRC/out
```

## 安装

预编译产物见 **Releases**。手动安装：

```sh
install -m 0755 libvulkan_panfrost.so /usr/lib/libvulkan_panfrost.so

cat >/usr/share/vulkan/icd.d/panfrost_icd.aarch64.json <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/usr/lib/libvulkan_panfrost.so",
        "api_version": "1.4.0"
    }
}
EOF
```

只想测试、不覆盖系统驱动：

```sh
VK_ICD_FILENAMES=$PWD/panfrost_icd.aarch64.json vulkaninfo --summary
VK_ICD_FILENAMES=$PWD/panfrost_icd.aarch64.json vkcube
```

要求：

- aarch64 Linux；
- mainline `panfrost` kmod（Mali-G76 / Bifrost）；
- Mesa Vulkan loader 与运行库；
- 内核 DTB 中 GPU / IOMMU / display 正常工作。

## 验证

```sh
vulkaninfo --summary
```

应看到：

```text
deviceName   = PanVK-G76 MC4
driverName   = panvk
driverInfo   = Mesa 27.0.0-devel (git-58f2c55854)
apiVersion   = 1.3.363
```

应用侧：

```sh
vkcube
```

## 已知限制

- 这是 **Vulkan** 驱动；OpenGL 仍由系统的 `panfrost_dri.so` 提供。
- Zink + PanVK 目前最高 OpenGL 3.2。
- PanVK `maxComputeWorkGroupInvocations = 384`，不满足部分 GL 4.3 要求。
- 客户端 WSI 走线性布局（`supports_modifiers = false`），不使用 AFBC modifier。
- 仅针对 MT6785 / Mali-G76 验证；其他 Bifrost 型号可尝试，但不保证。

## 许可

驱动源码和二进制来自 Mesa / JimVulkan/mali-panvk，遵循其上游许可
（Mesa 使用 MIT 许可）。构建脚本和文档仅用于复现该构建。
