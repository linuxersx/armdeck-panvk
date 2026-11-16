# armdeck-panvk

面向 **MT6785 / Mali-G76（Bifrost）** 的 Linux / Wayland 版 PanVK Vulkan ICD，
用于在 mainline `panfrost` 内核驱动上跑 Vulkan 应用、gamescope 和 Steam 大屏。

本仓库不是完整的 Mesa 分支，而是：

- 固定来源与 commit；
- 记录 Linux/Wayland 构建所需的裁剪恢复和 Bifrost WSI 修复；
- 提供可复现的构建脚本；
- 在 Releases 里提供预编译的 `libvulkan_panfrost.so`。

## 来源

本仓库构建的驱动来自以下两个上游：

- **Mesa**（Mesa 27.0.0-devel）
  <https://gitlab.freedesktop.org/mesa/mesa>
  构建脚本会从 Mesa main 恢复被裁剪的 `src/loader` 和 Vulkan WSI 头文件。

- **JimVulkan/mali-panvk**
  <https://github.com/JimVulkan/mali-panvk>
  固定 commit：`58f2c55854`
  这是面向 Android / Arm kbase 的 Mali PanVK 分支，保留了 mainline
  `panfrost` / `panthor` kmod 后端，包含 Bifrost 修复。

构建产物报告的版本：

```text
Device:      PanVK-G76 MC4
apiVersion:  1.3.363
driverInfo:  Mesa 27.0.0-devel (git-58f2c55854)
```

## 为什么需要这个仓库

上游 `mali-panvk` 是 Android-first 的，直接拿来在 Linux/Wayland 上构建会遇到：

1. 源码树裁掉了 Linux 构建需要的 `src/loader` 和部分 Vulkan WSI 头文件；
2. Mesa main 把一个 Wayland protocol key 改了名（`linux-dmabuf-v1`），
   而该分支的 WSI 仍用旧名 `linux-dmabuf-unstable-v1`；
3. Bifrost 的 WSI 和 null descriptor 路径有 Android 假设，需要小修。

本仓库把这些问题固化成一份可重复执行的构建脚本。

## Linux / Wayland WSI 修复

构建脚本会幂等地应用以下修改：

1. **`panvk_wsi.c`：`wl_sw_fallback = true`**
   合成器不暴露 `zwp_linux_dmabuf_v1` 时需要回退到 `wl_shm`，否则 surface
   query 返回 `VK_ERROR_SURFACE_LOST_KHR`。

2. **`panvk_vX_nir_lower_descriptors.c`：去掉 null descriptor 断言**
   该分支在 Bifrost 上会用内部 dummy resource 替代 null descriptor，但
   `textureSize` / `textureLevels` / `textureSamples` 三处仍保留
   `TODO/Bifrost` 断言。gamescope 调用这些路径时会 abort。

3. **`panvk_wsi.c`：`supports_modifiers = false`**
   避免 gamescope WSI 传入的显式 DRM modifier 触发
   `panvk_image_get_explicit_mod()` 断言。客户端 WSI buffer 因此以线性布局
   导出（`DRM_FORMAT_MOD_INVALID`）。

> 说明：vkcube 在 gamescope 下花屏的根因不在 PanVK，而是 gamescope 把
> `DRM_FORMAT_MOD_INVALID` 的 dma-buf 用 `VK_IMAGE_TILING_OPTIMAL` 导入，
> 被 PanVK 选成 AFBC。该问题由 gamescope 侧的补丁修复，不在本仓库。

## 构建

构建环境：**aarch64 Arch Linux ARM** 容器（或机器），需要网络。

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

运行：

```sh
./build-panvk-mali27.sh
```

脚本会：

```text
下载 JimVulkan/mali-panvk @ 58f2c55854（codeload tar.gz）
下载 Mesa main（只取 src/loader 和 include/vulkan）
适配被改名的 Wayland protocol key
应用三处 Bifrost WSI / null descriptor 修复
meson setup -Dvulkan-drivers=panfrost -Dplatforms=wayland ...
ninja
输出 libvulkan_panfrost.so + panfrost_icd.aarch64.json
```

可用环境变量：

```text
PANVK_COMMIT   覆盖固定 commit
SRC            源码目录，默认 /work/mali-panvk
BUILD          构建目录，默认 $SRC/build-linux
OUT            产物目录，默认 /out/armdeck-panvk
CACHE          下载缓存目录，默认 /work
MESA_URL       覆盖 Mesa main tarball 地址
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

只想测试、不覆盖系统驱动时：

```sh
VK_ICD_FILENAMES=/path/to/panfrost_icd.aarch64.json vulkaninfo --summary
VK_ICD_FILENAMES=/path/to/panfrost_icd.aarch64.json vkcube
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
# gamescope 直通 DRM
gamescope --backend drm -W 960 -H 640 --force-orientation right \
  --force-composition-rotation -- vkcube
```

## 已知限制

- 这是 **Vulkan** 驱动；OpenGL 仍由系统的 `panfrost_dri.so` 提供。
- Zink + PanVK 目前最高 OpenGL 3.2；Steam UI 的 GL 合成器要求 4.3，
  因此侧边栏等仍可能走 CPU 合成。
- PanVK `maxComputeWorkGroupInvocations = 384`，不满足部分 GL 4.3 要求。
- 客户端 WSI 走线性布局（`supports_modifiers = false`），不使用 AFBC modifier。
- 仅针对 MT6785 / Mali-G76 验证；其他 Bifrost 型号可尝试，但不保证。

## 许可

驱动二进制和修改后的源码来自 Mesa / JimVulkan/mali-panvk，遵循其上游许可
（Mesa 使用 MIT 许可）。本仓库的构建脚本和文档仅用于复现该构建。
