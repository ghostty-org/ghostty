#if defined(GHOSTTY_SIMD_INDEX_OF_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef GHOSTTY_SIMD_INDEX_OF_H_
#undef GHOSTTY_SIMD_INDEX_OF_H_
#else
#define GHOSTTY_SIMD_INDEX_OF_H_
#endif

#include <hwy/highway.h>
#include <optional>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

// Return the index of the first occurrence of `needle` in `input`, where
// the input and needle are already loaded into vectors.
template <class D, typename T = hn::TFromD<D>>
std::optional<size_t> IndexOfChunk(D d,
                                   hn::Vec<D> needle_vec,
                                   hn::Vec<D> input_vec) {
  // Compare the input vector with the needle vector. This produces
  // a vector where each lane is 0xFF if the corresponding lane in
  // `input_vec` is equal to the corresponding lane in `needle_vec`.
  const hn::Mask<D> eq_mask = hn::Eq(needle_vec, input_vec);

  // Find the index within the vector where the first true value is.
  const intptr_t pos = hn::FindFirstTrue(d, eq_mask);

  // If we found a match, return the index into the input.
  if (pos >= 0) {
    return std::optional<size_t>(static_cast<size_t>(pos));
  } else {
    return std::nullopt;
  }
}

// Return the index of the first occurrence of `needle` in `input` or
// `count` if not found.
template <class D, typename T = hn::TFromD<D>>
size_t IndexOfImpl(D d, T needle, const T* HWY_RESTRICT input, size_t count) {
  // Note: due to the simplicity of this operation and the general complexity
  // of SIMD, I'm going to overly comment this function to help explain the
  // implementation for future maintainers.

  // The number of lanes in the vector type.
  const size_t N = hn::Lanes(d);

  // Create a vector with all lanes set to `needle` so we can do a lane-wise
  // comparison with the input.
  const hn::Vec<D> needle_vec = Set(d, needle);

  // Compare N elements at a time.
  size_t i = 0;
  for (; i + N <= count; i += N) {
    // Load the N elements from our input into a vector and check the chunk.
    const hn::Vec<D> input_vec = hn::LoadU(d, input + i);
    if (auto pos = IndexOfChunk(d, needle_vec, input_vec)) {
      return i + pos.value();
    }
  }

  // Since we compare N elements at a time, we may have some elements left
  // if count modulo N != 0. We need to scan the remaining elements. To
  // be simple, we search one element at a time.
  if (i != count) {
    // Create a new vector with only one relevant lane.
    const hn::CappedTag<T, 1> d1;
    using D1 = decltype(d1);

    // Get an equally sized needle vector with only one lane.
    const hn::Vec<D1> needle1 = Set(d1, GetLane(needle_vec));

    // Go through the remaining elements and do similar logic to
    // the previous loop to find any matches.
    for (; i < count; ++i) {
      const hn::Vec<D1> input_vec = hn::LoadU(d1, input + i);
      const hn::Mask<D1> eq_mask = hn::Eq(needle1, input_vec);
      if (hn::AllTrue(d1, eq_mask))
        return i;
    }
  }

  return count;
}

size_t IndexOf(const uint8_t needle,
               const uint8_t* HWY_RESTRICT input,
               size_t count);

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

#endif  // GHOSTTY_SIMD_INDEX_OF_H_
