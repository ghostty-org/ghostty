// Generates code for every target that this compiler can support.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "simd/vt.cpp"  // this file
#include <hwy/foreach_target.h>           // must come before highway.h
#include <hwy/highway.h>

#include <simd/index_of.h>
#include <simd/simdutf.h>
#include <simd/utf8.h>
#include <simd/vt.h>
#include <vector>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

using T = uint8_t;

// Decode the UTF-8 text in input into output. Returns the number of decoded
// characters. This function assumes output is large enough.
//
// This function handles malformed UTF-8 sequences by inserting a
// replacement character (U+FFFD) and continuing to decode. This function
// will consume the entire input no matter what.
size_t DecodeUTF8(const uint8_t* HWY_RESTRICT input,
                  size_t count,
                  char32_t* output) {
  // Its possible for our input to be empty since DecodeUTF8UntilControlSeq
  // doesn't check for this.
  if (count == 0) {
    return 0;
  }

  // Assume no errors for fast path.
  const size_t decoded = simdutf::convert_utf8_to_utf32(
      reinterpret_cast<const char*>(input), count, output);
  if (decoded > 0) {
    return decoded;
  }

  // Errors in the UTF input, take a slow path and do a decode with
  // replacement (with U+FFFD). Note that simdutf doesn't have a
  // decode with replacement API:
  // https://github.com/simdutf/simdutf/issues/147
  //
  // Because of this, we use a separate library with heap allocation
  // that is much, much slower (the allocation is slower, the algorithm
  // is slower, etc.) This is just so we have something that works.
  // I want to replace this.
  std::vector<char> replacement_result;
  utf8::replace_invalid(input, input + count,
                        std::back_inserter(replacement_result), 0xFFFD);
  return DecodeUTF8(reinterpret_cast<const uint8_t*>(replacement_result.data()),
                    replacement_result.size(), output);
}

/// Decode the UTF-8 text in input into output until an escape
/// character is found. This returns the number of bytes consumed
/// from input and writes the number of decoded characters into
/// output_count.
///
/// This may return a value less than count even with no escape
/// character if the input ends with an incomplete UTF-8 sequence.
/// The caller should check the next byte manually to determine
/// if it is incomplete.
template <class D>
size_t DecodeUTF8UntilControlSeqImpl(D d,
                                     const T* HWY_RESTRICT input,
                                     size_t count,
                                     char32_t* output,
                                     size_t* output_count) {
  const size_t N = hn::Lanes(d);

  // Create a vector containing ESC since that denotes a control sequence.
  const hn::Vec<D> esc_vec = Set(d, 0x1B);

  // Compare N elements at a time.
  size_t i = 0;
  for (; i + N <= count; i += N) {
    // Load the N elements from our input into a vector.
    const hn::Vec<D> input_vec = hn::LoadU(d, input + i);

    // If we don't have any escapes we keep going. We want to accumulate
    // the largest possible valid UTF-8 sequence before decoding.
    // TODO(mitchellh): benchmark this vs decoding every time
    const auto esc_idx = IndexOfChunk(d, esc_vec, input_vec);
    if (!esc_idx) {
      continue;
    }

    // We have an ESC char, decode up to this point. We start by assuming
    // a valid UTF-8 sequence and slow-path into error handling if we find
    // an invalid sequence.
    *output_count = DecodeUTF8(input, i + esc_idx.value(), output);
    return i + esc_idx.value();
  }

  // If we have leftover input then we decode it one byte at a time (slow!)
  // using pretty much the same logic as above.
  if (i != count) {
    const hn::CappedTag<T, 1> d1;
    using D1 = decltype(d1);
    const hn::Vec<D1> esc1 = Set(d1, GetLane(esc_vec));
    for (; i < count; ++i) {
      const hn::Vec<D1> input_vec = hn::LoadU(d1, input + i);
      const auto esc_idx = IndexOfChunk(d1, esc1, input_vec);
      if (!esc_idx) {
        continue;
      }

      *output_count = DecodeUTF8(input, i + esc_idx.value(), output);
      return i + esc_idx.value();
    }
  }

  // If we reached this point, its possible for our input to have an
  // incomplete sequence because we're consuming the full input. We need
  // to trim any incomplete sequences from the end of the input.
  const size_t trimmed_len =
      simdutf::trim_partial_utf8(reinterpret_cast<const char*>(input), i);
  *output_count = DecodeUTF8(input, trimmed_len, output);
  return trimmed_len;
}

size_t DecodeUTF8UntilControlSeq(const uint8_t* HWY_RESTRICT input,
                                 size_t count,
                                 char32_t* output,
                                 size_t* output_count) {
  const hn::ScalableTag<uint8_t> d;
  return DecodeUTF8UntilControlSeqImpl(d, input, count, output, output_count);
}

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

// HWY_ONCE is true for only one of the target passes
#if HWY_ONCE

namespace ghostty {

HWY_EXPORT(DecodeUTF8UntilControlSeq);

size_t DecodeUTF8UntilControlSeq(const uint8_t* HWY_RESTRICT input,
                                 size_t count,
                                 char32_t* output,
                                 size_t* output_count) {
  return HWY_DYNAMIC_DISPATCH(DecodeUTF8UntilControlSeq)(input, count, output,
                                                         output_count);
}

}  // namespace ghostty

extern "C" {

size_t ghostty_simd_decode_utf8_until_control_seq(const uint8_t* HWY_RESTRICT
                                                      input,
                                                  size_t count,
                                                  char32_t* output,
                                                  size_t* output_count) {
  return ghostty::DecodeUTF8UntilControlSeq(input, count, output, output_count);
}

}  // extern "C"

#endif  // HWY_ONCE
