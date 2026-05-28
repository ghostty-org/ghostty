// Generates code for every target that this compiler can support.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "simd/vt.cpp"  // this file
#include <hwy/foreach_target.h>           // must come before highway.h
#include <hwy/highway.h>

#include <simdutf.h>

#include <simd/index_of.h>
#include <simd/vt.h>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

using T = uint8_t;

// Compute the length of the maximal subpart of an ill-formed UTF-8
// subsequence starting at p[0], per Unicode Table 3-7 and the W3C
// "U+FFFD Substitution of Maximal Subparts" algorithm.
//
// The maximal subpart is the longest initial subsequence that is either:
//   (a) the start of a well-formed sequence, or
//   (b) a single byte.
// Each maximal subpart maps to exactly one U+FFFD.
static size_t MaximalSubpart(const unsigned char* p, size_t len) {
  if (len == 0) return 0;

  unsigned char b0 = p[0];

  // Continuation bytes (80-BF), overlong leads (C0-C1), or invalid (F5-FF):
  // each is its own maximal subpart of length 1.
  if (b0 < 0xC2 || b0 > 0xF4) return 1;

  // Determine the expected sequence length and the valid range for each
  // continuation byte per Unicode Table 3-7.
  size_t seq_len;
  unsigned char lo[3], hi[3];

  if (b0 <= 0xDF) {
    seq_len = 2;
    lo[0] = 0x80; hi[0] = 0xBF;
  } else if (b0 == 0xE0) {
    seq_len = 3;
    lo[0] = 0xA0; hi[0] = 0xBF;
    lo[1] = 0x80; hi[1] = 0xBF;
  } else if (b0 <= 0xEC) {
    seq_len = 3;
    lo[0] = 0x80; hi[0] = 0xBF;
    lo[1] = 0x80; hi[1] = 0xBF;
  } else if (b0 == 0xED) {
    seq_len = 3;
    lo[0] = 0x80; hi[0] = 0x9F;
    lo[1] = 0x80; hi[1] = 0xBF;
  } else if (b0 <= 0xEF) {
    seq_len = 3;
    lo[0] = 0x80; hi[0] = 0xBF;
    lo[1] = 0x80; hi[1] = 0xBF;
  } else if (b0 == 0xF0) {
    seq_len = 4;
    lo[0] = 0x90; hi[0] = 0xBF;
    lo[1] = 0x80; hi[1] = 0xBF;
    lo[2] = 0x80; hi[2] = 0xBF;
  } else if (b0 <= 0xF3) {
    seq_len = 4;
    lo[0] = 0x80; hi[0] = 0xBF;
    lo[1] = 0x80; hi[1] = 0xBF;
    lo[2] = 0x80; hi[2] = 0xBF;
  } else {  // b0 == 0xF4
    seq_len = 4;
    lo[0] = 0x80; hi[0] = 0x8F;
    lo[1] = 0x80; hi[1] = 0xBF;
    lo[2] = 0x80; hi[2] = 0xBF;
  }

  // Check continuation bytes against their specific valid ranges.
  // The maximal subpart extends as far as bytes match.
  size_t valid = 1;  // lead byte counts
  for (size_t i = 0; i < seq_len - 1 && valid < len; i++) {
    unsigned char cb = p[valid];
    if (cb < lo[i] || cb > hi[i]) break;
    valid++;
  }

  // If we matched all bytes, the sequence is structurally valid
  // (shouldn't happen since we're called on an error), but cap
  // to avoid skipping a valid sequence.
  if (valid == seq_len) return valid;

  return valid;
}

// Trim trailing bytes that form a valid-but-incomplete UTF-8 sequence.
// Only trims sequences whose bytes so far match Table 3-7 ranges (i.e.,
// truly partial sequences that could be completed by future input).
// Invalid lead bytes (C0, C1, F5-FF) or mismatched continuations are NOT
// trimmed — they will be handled as errors by DecodeUTF8.
static size_t TrimValidPartialUTF8(const uint8_t* input, size_t len) {
  if (len == 0) return 0;

  // Find the start of a potential trailing partial sequence by scanning
  // backwards from the end. We look for a lead byte (C2-F4) that could
  // start a multi-byte sequence, possibly followed by continuation bytes.
  //
  // We check up to the last 4 bytes (max UTF-8 sequence length).
  size_t check_start = len > 4 ? len - 4 : 0;
  for (size_t pos = len; pos > check_start; pos--) {
    unsigned char b = input[pos - 1];

    // Skip continuation bytes — they might belong to the partial sequence.
    if ((b & 0xC0) == 0x80) continue;

    // Found a non-continuation byte. Only valid multi-byte leads (C2-F4)
    // can start a partial sequence worth trimming. Anything else (ASCII,
    // C0, C1, F5-FF) should be consumed by DecodeUTF8.
    if (b < 0xC2 || b > 0xF4) return len;

    // Determine expected sequence length from the lead byte.
    size_t expected;
    if (b <= 0xDF)
      expected = 2;
    else if (b <= 0xEF)
      expected = 3;
    else
      expected = 4;

    size_t seq_remaining = len - (pos - 1);

    // If we have all expected bytes, the sequence is complete (not partial).
    if (seq_remaining >= expected) return len;

    // Check if the trailing bytes form a valid prefix using MaximalSubpart.
    const unsigned char* seq_start = input + pos - 1;
    size_t subpart = MaximalSubpart(seq_start, seq_remaining);

    // Only trim if ALL trailing bytes are part of the valid prefix
    // (the sequence is valid-so-far but incomplete).
    if (subpart == seq_remaining) {
      return pos - 1;
    }

    // The sequence is ill-formed, don't trim — let DecodeUTF8 handle it.
    return len;
  }

  return len;
}

// Decode the UTF-8 text in input into output. Returns the number of decoded
// characters. This function assumes output is large enough.
//
// This function handles malformed UTF-8 sequences by inserting a
// replacement character (U+FFFD) following the W3C/Unicode "U+FFFD
// Substitution of Maximal Subparts" algorithm and continuing to decode.
// This function will consume the entire input no matter what.
size_t DecodeUTF8(const uint8_t* HWY_RESTRICT input,
                  size_t count,
                  char32_t* output) {
  // Its possible for our input to be empty since DecodeUTF8UntilControlSeq
  // doesn't check for this.
  if (count == 0) {
    return 0;
  }

  // Decode UTF-8 to UTF-32, replacing invalid sequences with U+FFFD.
  const char* in = reinterpret_cast<const char*>(input);
  size_t remaining = count;
  char32_t* out = output;
  while (remaining > 0) {
    auto r = simdutf::convert_utf8_to_utf32_with_errors(in, remaining, out);

    // If the decode was a full success then we're done!
    if (r.error == simdutf::SUCCESS) {
      out += r.count;
      break;
    }

    // On error, r.count is the input byte position of the error.
    // The output buffer is already written up to that point, but
    // we need count_utf8 to find how many char32_t that produced.
    out += simdutf::count_utf8(in, r.count);

    // Compute the maximal subpart at the error position and emit
    // a single U+FFFD for it.
    const unsigned char* err_pos =
        reinterpret_cast<const unsigned char*>(in + r.count);
    size_t err_remaining = remaining - r.count;
    size_t skip = r.count + MaximalSubpart(err_pos, err_remaining);

    *out++ = 0xFFFD;

    in += skip;
    remaining -= skip;
  }

  return static_cast<size_t>(out - output);
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
    const size_t esc_idx = IndexOfChunk(d, esc_vec, input_vec);
    if (esc_idx == kNotFound) {
      continue;
    }

    // We have an ESC char, decode up to this point. We start by assuming
    // a valid UTF-8 sequence and slow-path into error handling if we find
    // an invalid sequence.
    *output_count = DecodeUTF8(input, i + esc_idx, output);
    return i + esc_idx;
  }

  // If we have leftover input then we decode it one byte at a time (slow!)
  // using pretty much the same logic as above.
  if (i != count) {
    const hn::CappedTag<T, 1> d1;
    using D1 = decltype(d1);
    const hn::Vec<D1> esc1 = Set(d1, hn::GetLane(esc_vec));
    for (; i < count; ++i) {
      const hn::Vec<D1> input_vec = hn::LoadU(d1, input + i);
      const size_t esc_idx = IndexOfChunk(d1, esc1, input_vec);
      if (esc_idx == kNotFound) {
        continue;
      }

      *output_count = DecodeUTF8(input, i + esc_idx, output);
      return i + esc_idx;
    }
  }

  // If we reached this point, its possible for our input to have an
  // incomplete sequence because we're consuming the full input. We need
  // to trim any incomplete sequences from the end of the input.
  //
  // We use our own trim instead of simdutf::trim_partial_utf8 because
  // we only want to trim sequences that are valid-so-far (true partial
  // sequences that may be completed by future input). Invalid bytes
  // like C0, C1, F5-FF should NOT be trimmed — they should be passed
  // through to DecodeUTF8 which will replace them with U+FFFD per the
  // maximal subpart algorithm.
  const size_t trimmed_len = TrimValidPartialUTF8(input, i);
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
