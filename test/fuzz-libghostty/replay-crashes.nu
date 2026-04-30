#!/usr/bin/env nu

# Replay AFL++ crash files against their corresponding fuzzer binaries.
#
# AFL++ stores crashing inputs as raw byte files under:
#   afl-out/<fuzzer>/default/crashes/
#
# Each file's name encodes metadata about how the crash was found, e.g.:
#   id:000001,sig:06,src:004129,time:690036,execs:1989720,op:havoc,rep:4
#
# The fuzzer binaries (fuzz-parser, fuzz-stream) read input from stdin,
# so each crash file is replayed by piping it into the binary:
#   open --raw <crash-file> | fuzz-<name>
#
# Modes:
#   (default)   Replay every crash file and report pass/fail.
#   --list      Print crash file paths, one per line (no replay).
#   --json      Emit structured JSON with fuzzer name, file path,
#               binary path, and a ready-to-run replay command.
#               Useful for LLM agents that need to enumerate and
#               selectively replay specific crashes.
#   --fuzzer    Restrict to a single fuzzer target (e.g. "stream").

def main [
    afl_out: string = "afl-out"  # Path to the AFL++ output directory
    --list (-l)                   # List crash files without replaying
    --json (-j)                   # Output as JSON (implies --list)
    --fuzzer (-f): string         # Only process this fuzzer (e.g. "stream" or "parser")
] {
    # Directory where `zig build` places the instrumented fuzzer binaries.
    let bin_dir = "zig-out/bin"

    # All known fuzzer targets. Each one has a corresponding binary
    # named fuzz-<name> and AFL++ output under afl-out/<name>/.
    let all_fuzzers = [parser stream]

    # If --fuzzer is given, restrict to just that target; otherwise run all.
    let fuzzers = if $fuzzer != null { [$fuzzer] } else { $all_fuzzers }

    # --json implies --list (we never replay in JSON mode).
    let list_only = $list or $json

    # Accumulator for --list/--json output records.
    mut results = []

    # Counter for crash files that still reproduce (non-zero exit from binary).
    mut failures = 0

    for fuzz in $fuzzers {
        # AFL++ writes crash inputs to <out>/<fuzzer>/default/crashes/.
        let crashes_dir = $"($afl_out)/($fuzz)/default/crashes"

        # The replay binary for this fuzzer target.
        let binary = $"($bin_dir)/fuzz-($fuzz)"

        # Skip this fuzzer if no crashes directory exists (fuzzer may not
        # have been run, or it found no crashes).
        if not ($crashes_dir | path exists) {
            continue
        }

        # Gather all crash files, filtering out:
        #   - Directories (AFL++ may create subdirs like .synced/)
        #   - README.txt (AFL++ places a README in the crashes dir)
        let crash_files = (ls $crashes_dir
            | where type == file
            | where { |f| ($f.name | path basename) != "README.txt" }
            | get name)

        # In list-only mode, collect metadata about each crash file
        # without actually replaying it. This lets an LLM enumerate
        # crashes and decide which ones to investigate.
        if $list_only {
            for crash_file in $crash_files {
                $results = ($results | append {
                    fuzzer: $fuzz,
                    file: $crash_file,
                    binary: $binary,
                    replay_cmd: $"open --raw ($crash_file) | ($binary)",
                })
            }
            continue
        }

        # In replay mode, we need the binary to exist.
        if not ($binary | path exists) {
            print -e $"WARNING: binary ($binary) not found, skipping ($fuzz)"
            continue
        }

        # Replay each crash file by piping its raw bytes into the fuzzer
        # binary via stdin. The binary exits non-zero if the crash
        # reproduces (e.g. SIGABRT / signal 6).
        for crash_file in $crash_files {
            print $"==> ($crash_file)"
            let result = do -i { open --raw $crash_file | run-external $binary }
            if $result != null {
                $failures += 1
            }
        }
    }

    # Emit collected results in the requested format.
    if $list_only {
        if $json {
            # JSON output: array of objects, each with fuzzer, file,
            # binary, and a replay_cmd string an LLM can execute directly.
            print ($results | to json)
        } else {
            # Plain text: one file path per line.
            for r in $results {
                print $r.file
            }
        }
        return
    }

    # Summary: exit 1 if any crashes still reproduce so CI / scripts
    # can detect regressions.
    if $failures > 0 {
        print $"FAILED: ($failures) crash\(es\) still reproduce"
        exit 1
    }

    print "All crash files replayed."
}
