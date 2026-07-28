#!/usr/bin/env nu

# This script downloads external dependencies from build.zig.zon.json that
# are not already mirrored at deps.files.ghostty.org, saves them to a local
# directory, and updates the build.zig.zon files (the root one as well as
# every pkg/*/build.zig.zon) to point to the new mirror URLs.
#
# The downloaded files are unmodified so their checksums and content hashes
# will match the originals.
#
# After running this script, the files in the output directory can be uploaded
# to blob storage, and the build.zig.zon files will already be updated with
# the new URLs.
def main [
  --output: string = "tmp-mirror", # Output directory for the mirrored files
  --prefix: string = "https://deps.files.ghostty.org/", # Final URL prefix to ignore
  --dry-run, # Print what would be downloaded without downloading
] {
  let script_dir = ($env.CURRENT_FILE | path dirname)
  let root_dir = ($script_dir | path join ".." ".." | path expand)
  let input_file = ($root_dir | path join "build.zig.zon.json")
  let output_dir = $output

  # All build.zig.zon files that may reference external URLs: the root
  # one plus every package under pkg/. build.zig.zon.json is generated
  # from the full dependency tree so it covers all of these.
  let zon_files = (
    [($root_dir | path join "build.zig.zon")]
    | append (glob ($root_dir | path join "pkg" "*" "build.zig.zon"))
    | sort
  )

  # Ensure the output directory exists
  mkdir $output_dir

  # Read and parse the JSON file
  let deps = open $input_file

  # Track URL replacements for build.zig.zon
  mut url_replacements = []

  # Process each dependency
  for entry in ($deps | transpose key value) {
    let key = $entry.key
    let name = $entry.value.name
    let url = $entry.value.url

    # Skip URLs that don't start with http(s)
    if not ($url | str starts-with "http") {
      continue
    }

    # Skip URLs already hosted at the prefix
    if ($url | str starts-with $prefix) {
      continue
    }

    # Extract the file extension from the URL
    let extension = ($url | parse -r '(\.[a-z0-9]+(?:\.[a-z0-9]+)?)$' | get -o capture0.0 | default "")

    # Try to extract commit hash (40 hex chars) from URL
    let commit_hash = ($url | parse -r '([a-f0-9]{40})' | get -o capture0.0 | default "")

    # Try to extract date pattern (YYYY-MM-DD or YYYYMMDD with optional suffixes)
    let date_pattern = ($url | parse -r '((?:release-)?20\d{2}(?:-?\d{2}){2}(?:[-]\d+)*(?:[-][a-z0-9]+)?)' | get -o capture0.0 | default "")

    # Build filename based on what we found
    let filename = if (not ($commit_hash | is-empty)) {
      $"($name)-($commit_hash)($extension)"
    } else if (not ($date_pattern | is-empty)) {
      $"($name)-($date_pattern)($extension)"
    } else {
      $"($key)($extension)"
    }
    let new_url = $"($prefix)($filename)"
    print $"($url) -> ($filename)"
    
    # Track the replacement
    $url_replacements = ($url_replacements | append {old: $url, new: $new_url})
    
    # Download the file
    if not $dry_run {
      http get $url | save -f ($output_dir | path join $filename)
    }
  }

  if $dry_run {
    print "Dry run complete - no files were downloaded\n"
  } else {
    print "All dependencies downloaded successfully\n"
  }

  # Apply the URL replacements to every build.zig.zon that references them.
  for zon_file in $zon_files {
    mut zon_content = (open --raw $zon_file)
    mut count = 0
    for replacement in $url_replacements {
      if ($zon_content | str contains $replacement.old) {
        $zon_content = ($zon_content | str replace --all $replacement.old $replacement.new)
        $count = $count + 1
      }
    }

    if $count == 0 {
      continue
    }

    let relative_path = ($zon_file | path relative-to $root_dir)
    if $dry_run {
      print $"Would update ($count) URLs in ($relative_path)"
    } else {
      # Backup the old file
      let backup_file = $"($zon_file).bak"
      cp $zon_file $backup_file
      $zon_content | save -f $zon_file
      print $"Updated ($count) URLs in ($relative_path), backup at ($relative_path).bak"
    }
  }
}
