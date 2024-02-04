#if defined(GHOSTTY_SIMD_VT_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef GHOSTTY_SIMD_VT_H_
#undef GHOSTTY_SIMD_VT_H_
#else
#define GHOSTTY_SIMD_VT_H_
#endif

#include <hwy/highway.h>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

#if HWY_ONCE

namespace ghostty {

typedef void (*PrintFunc)(const char32_t* chars, size_t count);

}  // namespace ghostty

#endif  // HWY_ONCE

#endif  // GHOSTTY_SIMD_VT_H_
