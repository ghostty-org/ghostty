// Generates code for every target that this compiler can support.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "example.cpp"  // this file
#include <hwy/foreach_target.h>  // must come before highway.h
#include <hwy/highway.h>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {  // required: unique per target

// Can skip hn:: prefixes if already inside hwy::HWY_NAMESPACE.
namespace hn = hwy::HWY_NAMESPACE;

using T = float;

// Alternative to per-function HWY_ATTR: see HWY_BEFORE_NAMESPACE
void MulAddLoop(const T* HWY_RESTRICT mul_array,
                const T* HWY_RESTRICT add_array,
                const size_t size, T* HWY_RESTRICT x_array) {
  const hn::ScalableTag<T> d;
  for (size_t i = 0; i < size; i += hn::Lanes(d)) {
    const auto mul = hn::Load(d, mul_array + i);
    const auto add = hn::Load(d, add_array + i);
    auto x = hn::Load(d, x_array + i);
    x = hn::MulAdd(mul, x, add);
    hn::Store(x, d, x_array + i);
  }
}

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

// The table of pointers to the various implementations in HWY_NAMESPACE must
// be compiled only once (foreach_target #includes this file multiple times).
// HWY_ONCE is true for only one of these 'compilation passes'.
#if HWY_ONCE

namespace ghostty {

// This macro declares a static array used for dynamic dispatch.
HWY_EXPORT(MulAddLoop);

void CallMulAddLoop(const float* HWY_RESTRICT mul_array,
                const float* HWY_RESTRICT add_array,
                const size_t size, float* HWY_RESTRICT x_array) {
  // This must reside outside of HWY_NAMESPACE because it references (calls the
  // appropriate one from) the per-target implementations there.
  // For static dispatch, use HWY_STATIC_DISPATCH.
  return HWY_DYNAMIC_DISPATCH(MulAddLoop)(mul_array, add_array, size, x_array);
}

}  // namespace ghostty

extern "C" float example() {
    float mul_array[] {1, 2, 3, 4, 5};
    float add_array[] {2, 3, 4, 5, 6};
    float x_array[] {0, 0, 0, 0, 0};
    ghostty::CallMulAddLoop(mul_array, add_array, 5, x_array);
    return x_array[0];
}

#endif  // HWY_ONCE
