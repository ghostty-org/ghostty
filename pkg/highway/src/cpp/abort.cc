// Copyright 2019 Google LLC
// Copyright 2024 Arm Limited and/or its affiliates <open-source-office@arm.com>
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: BSD-3-Clause

// Vendored from google/highway hwy/abort.cc at commit:
// 66486a10623fa0d72fe91260f96c892e41aceb06
//
// Local modifications:
// - Removed stdio/stdlib/string/sanitizer-backed formatting and logging paths
//   so this file no longer pulls in libc/libc++ symbols.
// - Replaced std::atomic storage with compiler atomics on plain function
//   pointers to preserve thread-safe handler installation without libc++.
// - Kept only the Warn/Abort symbol surface Highway's runtime dispatch needs,
//   with a trap-only fallback when no abort handler is installed.
//
// Why:
// - Ghostty only needs Highway's runtime dispatch support here, not its
//   formatted stderr diagnostics.
// - Keeping this translation unit libc/libc++ free lets pkg/highway build as a
//   small vendored shim around Zig-driven target detection.

#include "hwy/abort.h"

#include "hwy/base.h"

namespace hwy {

namespace {

WarnFunc g_warn_func = nullptr;
AbortFunc g_abort_func = nullptr;

}  // namespace

HWY_DLLEXPORT WarnFunc& GetWarnFunc() {
  return g_warn_func;
}

HWY_DLLEXPORT AbortFunc& GetAbortFunc() {
  return g_abort_func;
}

HWY_DLLEXPORT WarnFunc SetWarnFunc(WarnFunc func) {
  return __atomic_exchange_n(&g_warn_func, func, __ATOMIC_SEQ_CST);
}

HWY_DLLEXPORT AbortFunc SetAbortFunc(AbortFunc func) {
  return __atomic_exchange_n(&g_abort_func, func, __ATOMIC_SEQ_CST);
}

HWY_DLLEXPORT void HWY_FORMAT(3, 4)
    Warn(const char* file, int line, const char* format, ...) {
  WarnFunc handler = __atomic_load_n(&g_warn_func, __ATOMIC_SEQ_CST);
  if (handler != nullptr) {
    handler(file, line, format);
  }
}

HWY_DLLEXPORT HWY_NORETURN void HWY_FORMAT(3, 4)
    Abort(const char* file, int line, const char* format, ...) {
  AbortFunc handler = __atomic_load_n(&g_abort_func, __ATOMIC_SEQ_CST);
  if (handler != nullptr) {
    handler(file, line, format);
  }

  __builtin_trap();
}

}  // namespace hwy
