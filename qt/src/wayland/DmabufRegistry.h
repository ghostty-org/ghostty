// Compositor dmabuf modifier registry.
//
// Process-wide read-only table of `(drm_format, [modifier])` pairs the
// compositor advertises via `zwp_linux_dmabuf_v1`. libghostty's Vulkan
// renderer queries this through the
// `ghostty_platform_vulkan_s.get_supported_modifiers` callback when
// picking a modifier the compositor will accept on attach — without
// that intersection, drivers that don't expose `COLOR_ATTACHMENT_BIT`
// for `LINEAR` (NVIDIA) can't get into Target's direct-export mode at
// all and have to fall back to the legacy CPU-readback path.
//
// Why a header of its own instead of living on
// `wayland::SubsurfacePresenter`? The presenter is per-widget; the
// registry is process-wide and read-only after a one-shot prime. They
// share `globalState()` machinery internally
// (`SubsurfacePresenter.cpp`) but their public surfaces are unrelated
// concerns.
//
// Wayland-only by project decision (the Qt frontend is Wayland-only;
// see `feedback-qt-no-x11` memory). On non-Wayland QPA both functions
// are no-ops — `primeDmabufModifierRegistry` returns immediately and
// `supportedDmabufModifiers` returns 0 — so callers can stay
// runtime-agnostic.

#pragma once

#include <cstddef>
#include <cstdint>

namespace wayland {

// Eagerly discover the compositor's dmabuf modifier list on the
// CALLING THREAD. MUST be called from the GUI thread before any
// `supportedDmabufModifiers` reader runs (typically the libghostty
// renderer thread). Safe to call multiple times — discovery happens
// exactly once via the underlying `globalState`'s latched `searched`
// flag.
//
// Idempotent no-op if the QPA isn't Wayland or the
// QPlatformNativeInterface lookup fails.
void primeDmabufModifierRegistry();

// Read the cached compositor-supported DRM modifiers for the given
// DRM_FORMAT_* fourcc. Returns the number of modifiers actually
// written to `out` (capped at `capacity`). Pass `out=nullptr,
// capacity=0` to query the total count.
//
// Thread-safe for readers once `primeDmabufModifierRegistry` has
// returned. Returns 0 if the registry hasn't been primed yet or the
// format isn't advertised.
std::size_t supportedDmabufModifiers(std::uint32_t drm_format,
                                     std::uint64_t *out,
                                     std::size_t capacity);

} // namespace wayland
