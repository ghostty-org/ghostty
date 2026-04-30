// Vendored from google/highway hwy/targets.cc at commit:
// 66486a10623fa0d72fe91260f96c892e41aceb06
//
// Local modifications:
// - Dropped upstream CPU feature probing and platform-specific detection code
//   in favor of Ghostty's Zig-provided ghostty_hwy_detect_targets().
// - Removed the HWY_WARN baseline-mismatch diagnostic path so this file does
//   not depend on libc-backed formatting/logging.
// - Kept only the chosen-target bookkeeping and runtime dispatch state that
//   Highway's HWY_DYNAMIC_DISPATCH machinery needs.
// - Added hwy_supported_targets() as a small C shim for Zig to query the final
//   supported target mask.
//
// Why:
// - Ghostty wants a minimal vendored Highway runtime that avoids direct libc
//   usage and lets Zig own target detection policy.
// - Narrowing this file to dispatch state makes the local fork easier to audit
//   and maintain than carrying upstream's full platform detection surface.

#include "hwy/targets.h"

namespace hwy {

extern "C" int64_t ghostty_hwy_detect_targets();

// Vendored from Highway's hwy/targets.cc. Ghostty provides target detection in
// Zig, so this TU only retains the runtime dispatch/chosen-target state.
static int64_t DetectTargets() {
  int64_t bits = HWY_SCALAR | HWY_EMU128;

#if (HWY_ARCH_X86 || HWY_ARCH_ARM || HWY_ARCH_PPC || HWY_ARCH_S390X || \
     HWY_ARCH_RISCV || HWY_ARCH_LOONGARCH) && \
    HWY_HAVE_RUNTIME_DISPATCH
  bits |= ghostty_hwy_detect_targets();
#else
  bits |= HWY_ENABLED_BASELINE;
#endif

  return bits;
}

// When running tests, this value can be set to the mocked supported targets
// mask. Only written to from a single thread before the test starts.
static int64_t supported_targets_for_test_ = 0;

// Mask of targets disabled at runtime with DisableTargets.
static int64_t supported_mask_ = LimitsMax<int64_t>();

HWY_DLLEXPORT void DisableTargets(int64_t disabled_targets) {
  supported_mask_ = static_cast<int64_t>(~disabled_targets);
  GetChosenTarget().DeInit();
}

HWY_DLLEXPORT void SetSupportedTargetsForTest(int64_t targets) {
  supported_targets_for_test_ = targets;
  GetChosenTarget().DeInit();
}

HWY_DLLEXPORT int64_t SupportedTargets() {
  int64_t targets = supported_targets_for_test_;
  if (HWY_LIKELY(targets == 0)) {
    targets = DetectTargets();
    GetChosenTarget().Update(targets);
  }

  targets &= supported_mask_;
  return targets == 0 ? HWY_STATIC_TARGET : targets;
}

HWY_DLLEXPORT ChosenTarget& GetChosenTarget() {
  static ChosenTarget chosen_target;
  return chosen_target;
}

}  // namespace hwy

extern "C" int64_t hwy_supported_targets() {
  return hwy::SupportedTargets();
}
