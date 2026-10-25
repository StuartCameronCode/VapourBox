#!/usr/bin/env bash
# Give a CI runner a Vulkan device, so the ncnn-on-Vulkan features (RIFE, and
# Real-ESRGAN / Real-CUGAN upscaling) are actually exercised rather than skipped.
#
# The hosted runners have no GPU, so every one gets Mesa's lavapipe, a Vulkan
# driver that runs on the CPU — slow, but the same plugin, model and script
# path a user's GPU takes, and ncnn accepts a CPU device. That includes macOS
# arm64: those runners are VMs whose Metal device MoltenVK cannot open (it
# segfaults creating the instance — CI run 40155693557, 2026-10-25).
#
# Wherever a device is provisioned this sets VAPOURBOX_EXPECT_VULKAN=1, and the
# GPU tests then FAIL rather than skip if a feature reports itself unavailable
# (app/test/support/gpu_expectations.dart). On a platform that does not ship
# the features (macos-x64, linux-arm64) nothing is provisioned and the tests
# assert the "not available for this platform" answer instead.
#
# Usage: provision-vulkan.sh <platform>   (macos-arm64, windows-x64, linux-x64, …)
set -euo pipefail

platform="${1:?usage: provision-vulkan.sh <platform>}"

# Windows: the Khronos loader from LunarG's runtime components and lavapipe from
# mesa-dist-win (MIT), each pinned by hash. Keep these with the README's note.
VKRT_VERSION="1.4.328.1"
VKRT_SHA256="293efbb2c11e60429df7770f40e3c5c811a7fa42af81de0cc41e8718ddb2b373"
MESA_VERSION="26.2.2"
MESA_SHA256="0f21394d44036019bb5c07a3788dd278fd7b7b3469077a4686f0d639e8e874a1"

case "$platform" in
  linux-x64)
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers libvulkan1 vulkan-tools
    vulkaninfo --summary || true
    echo "VAPOURBOX_EXPECT_VULKAN=1" >> "$GITHUB_ENV"
    ;;
  windows-x64)
    dir="$RUNNER_TEMP/vulkan"
    rm -rf "$dir" && mkdir -p "$dir"
    curl -fsSL -o "$dir/vkrt.zip" \
      "https://sdk.lunarg.com/sdk/download/$VKRT_VERSION/windows/VulkanRT-X64-$VKRT_VERSION-Components.zip"
    echo "$VKRT_SHA256  $dir/vkrt.zip" | sha256sum -c -
    unzip -q -j "$dir/vkrt.zip" \
      "VulkanRT-X64-$VKRT_VERSION-Components/x64/vulkan-1.dll" \
      "VulkanRT-X64-$VKRT_VERSION-Components/x64/vulkaninfo.exe" -d "$dir"
    curl -fsSL -o "$dir/mesa.7z" \
      "https://github.com/pal1000/mesa-dist-win/releases/download/$MESA_VERSION/mesa3d-$MESA_VERSION-release-msvc.7z"
    echo "$MESA_SHA256  $dir/mesa.7z" | sha256sum -c -
    "/c/Program Files/7-Zip/7z.exe" x -y -o"$dir/mesa" "$dir/mesa.7z" \
      x64/vulkan_lvp.dll x64/lvp_icd.x86_64.json >/dev/null
    icd="$(cygpath -w "$dir/mesa/x64/lvp_icd.x86_64.json")"
    # The loader reads VK_DRIVER_FILES; older loaders read VK_ICD_FILENAMES.
    echo "VK_DRIVER_FILES=$icd" >> "$GITHUB_ENV"
    echo "VK_ICD_FILENAMES=$icd" >> "$GITHUB_ENV"
    # vulkan-1.dll on PATH, where the plugins' LoadLibrary finds it.
    cygpath -w "$dir" >> "$GITHUB_PATH"
    VK_DRIVER_FILES="$icd" "$dir/vulkaninfo.exe" --summary || true
    echo "VAPOURBOX_EXPECT_VULKAN=1" >> "$GITHUB_ENV"
    ;;
  macos-arm64)
    # Homebrew's mesa builds lavapipe on macOS (vulkan-drivers=swrast), and
    # vulkan-loader is the Khronos loader. ncnn dlopens libvulkan.1.dylib before
    # falling back to the MoltenVK the scripts preload, so with the loader
    # findable both plugins take lavapipe through it — the path any Mac with a
    # loader installed takes. Only the loader is exposed, in ~/lib — the first
    # directory on dyld's *default* fallback path — never Homebrew's lib/,
    # which could stand in for a library missing from the bundle and hide
    # that. Not DYLD_FALLBACK_LIBRARY_PATH: the bundle's vspipe is a /bin/bash
    # wrapper, and SIP strips every DYLD_* variable when a protected binary
    # runs, so it never reached the plugins (CI run 40157771950).
    # Not pinned: Homebrew has no version pins (bottles exist for macos-15).
    brew install --quiet mesa vulkan-loader vulkan-tools
    prefix="$(brew --prefix)"
    icd="$(ls "$prefix"/share/vulkan/icd.d/lvp_icd*.json | head -1)"
    mkdir -p "$HOME/lib"
    cp -L "$prefix/lib/libvulkan.1.dylib" "$HOME/lib/"
    echo "VK_DRIVER_FILES=$icd" >> "$GITHUB_ENV"
    echo "VK_ICD_FILENAMES=$icd" >> "$GITHUB_ENV"
    VK_DRIVER_FILES="$icd" vulkaninfo --summary || true
    echo "VAPOURBOX_EXPECT_VULKAN=1" >> "$GITHUB_ENV"
    ;;
  *)
    echo "No GPU features ship on $platform; the tests assert that answer instead."
    ;;
esac
