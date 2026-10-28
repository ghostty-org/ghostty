#!/usr/bin/env nu

def fail [message: string] {
  print -e $message
  exit 1
}

def main [
  binary: path
  --expect-platform: int # LC_BUILD_VERSION platform value
  --expect-arch: string # Mach-O architecture name
  --expect-encryption # Require LC_ENCRYPTION_INFO_64
] {
  if not ($binary | path exists) {
    fail $"dylib not found: ($binary)"
  }

  # Verify the dylib contains exactly the architecture requested by the build
  # matrix before interpreting any target-specific Mach-O load commands.
  let actual_arch = (^lipo -archs $binary | str trim)
  if $actual_arch != $expect_arch {
    fail $"expected architecture ($expect_arch), found ($actual_arch)"
  }

  # Framework consumers load this dylib through @rpath. Keep this stable even
  # though the installed file also has versioned compatibility symlinks.
  let install_names = (^otool -D $binary | lines | skip 1)
  if ($install_names | length) != 1 {
    fail "expected exactly one dylib install name"
  }

  let install_name = ($install_names | first | str trim)
  if $install_name != "@rpath/libghostty-vt.dylib" {
    fail $"unexpected install name: ($install_name)"
  }

  let load_command_lines = (^otool -l $binary | lines)
  let command_names = (
    $load_command_lines
    | parse --regex '^\s*cmd\s+(?<name>\S+)$'
    | get name
  )

  # LC_BUILD_VERSION distinguishes macOS, physical iOS, and the iOS Simulator.
  # Checking the numeric platform value catches an SDK or target-triple mixup.
  if ($command_names | where $it == "LC_BUILD_VERSION" | length) != 1 {
    fail "expected exactly one LC_BUILD_VERSION load command"
  }

  let platforms = (
    $load_command_lines
    | parse --regex '^\s*platform\s+(?<value>\d+)$'
    | get value
  )
  if ($platforms | length) != 1 {
    fail "expected exactly one LC_BUILD_VERSION platform field"
  }

  let actual_platform = ($platforms | first | into int)
  if $actual_platform != $expect_platform {
    fail $"expected platform ($expect_platform), found ($actual_platform)"
  }

  let encryption_commands = (
    $command_names
    | where { str starts-with "LC_ENCRYPTION_INFO" }
  )

  if $expect_encryption {
    # App Store processing requires physical iOS dylibs to reserve an
    # encryption range. cryptid remains zero until Apple encrypts the binary.
    if $encryption_commands != ["LC_ENCRYPTION_INFO_64"] {
      fail "missing or invalid LC_ENCRYPTION_INFO_64 load command"
    }

    let encryption_fields = (
      $load_command_lines
      | parse --regex '^\s*(?<name>cryptoff|cryptsize|cryptid)\s+(?<value>\d+)$'
    )
    if ($encryption_fields | length) != 3 {
      fail "missing or invalid LC_ENCRYPTION_INFO_64 fields"
    }

    let cryptoff = (
      $encryption_fields
      | where name == "cryptoff"
      | get 0.value
      | into int
    )
    let cryptsize = (
      $encryption_fields
      | where name == "cryptsize"
      | get 0.value
      | into int
    )
    let cryptid = (
      $encryption_fields
      | where name == "cryptid"
      | get 0.value
      | into int
    )
    if $cryptoff <= 0 or $cryptsize <= 0 or $cryptid != 0 {
      fail "missing or invalid LC_ENCRYPTION_INFO_64 fields"
    }
  } else {
    # Apple does not emit an encryption load command for macOS or Simulator
    # dylibs, so its presence would indicate the wrong platform was linked.
    if not ($encryption_commands | is-empty) {
      fail "unexpected LC_ENCRYPTION_INFO load command"
    }
  }

  # nm -gjU lists defined external symbols without addresses. The export list
  # passed to Apple's linker should leave only libghostty-vt's public C API.
  let exports = (
    ^nm -gjU $binary
    | lines
    | where { not ($in | is-empty) }
  )
  if ($exports | is-empty) {
    fail "dylib has no exported symbols"
  }

  let unexpected_exports = (
    $exports
    | where { not ($in | str starts-with "_ghostty_") }
  )
  if not ($unexpected_exports | is-empty) {
    fail $"unexpected exported symbols:\n($unexpected_exports | str join "\n")"
  }
}
