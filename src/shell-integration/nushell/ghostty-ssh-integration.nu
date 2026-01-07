# Enables SSH environment variable compatibility.
# Converts TERM from xterm-ghostty to xterm-256color
# and propagates COLORTERM, TERM_PROGRAM, and TERM_PROGRAM_VERSION
# check your sshd_config on remote host to see if these variables are accepted
def set_ssh_env []: nothing -> record<ssh_term: string, ssh_opts: list<string>> {
  return {
    ssh_term: "xterm-256color",
    ssh_opts: ["-o", "SetEnv COLORTERM=truecolor", "-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
  }
}

# Enables automatic terminfo installation on remote hosts.
# Attempts to install Ghostty's terminfo entry using infocmp and tic when
# connecting to hosts that lack it. 
# Requires infocmp to be available locally and tic to be available on remote hosts.
# Caches installations to avoid repeat installations.
def set_ssh_terminfo [
  ssh_opts: list<string>, 
  ssh_args: list<string>
]: [nothing -> record<ssh_term: string, ssh_opts: list<string>>] {
  mut ssh_opts = $ssh_opts
  let ssh_cfg = ^ssh -G ...($ssh_args)
    | lines
    | parse "{key} {value}"
    | where key in ["user", "hostname"]
    | select key value
    | transpose -rd
    | default { user: $env.USER, hostname: "localhost" }

  let ssh_id = $"($ssh_cfg.user)@($ssh_cfg.hostname)"
  let ghostty_bin = $env.GHOSTTY_BIN_DIR | path join "ghostty"

  let is_cached = (
    ^$ghostty_bin ...(["+ssh-cache", $"--host=($ssh_id)"])
    | complete
    | $in.exit_code == 0
  )

  if not $is_cached {
    let ssh_opts_copy = $ssh_opts
    let terminfo_data = try {^infocmp -0 -x xterm-ghostty} catch {
      print "Warning: Could not generate terminfo data."
      return {ssh_term: "xterm-256color", ssh_opts: $ssh_opts_copy}
    }

    print $"Setting up xterm-ghostty terminfo on ($ssh_cfg.hostname)..."

    let ctrl_path = (
      try {
        mktemp -td $"ghostty-ssh-($ssh_cfg.user).XXXXXX"
      } catch {
        $"/tmp/ghostty-ssh-($ssh_cfg.user).($nu.pid)"
      } | path join "socket"
    )

    let master_parts = $ssh_opts ++ ["-o" "ControlMaster=yes" "-o" $"ControlPath=($ctrl_path)" "-o" "ControlPersist=60s"] ++ $ssh_args

    ($terminfo_data) | ^ssh ...(
      $master_parts ++
      [
      '
      infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
      command -v tic >/dev/null 2>&1 || exit 1
      mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
      exit 1'
      ]
    )
    | complete
    | if $in.exit_code != 0 {
      print "Warning: Failed to install terminfo."
      return {ssh_term: "xterm-256color" ssh_opts: $ssh_opts}
    }

    ^$ghostty_bin ...(["+ssh-cache", $"--add=($ssh_id)"]) o+e>| ignore
    $ssh_opts ++= ["-o", $"ControlPath=($ctrl_path)"]
  }

  return {ssh_term: "xterm-ghostty", ssh_opts: $ssh_opts}
}

# SSH Integration
export def --wrapped ssh [...ssh_args: string]: any -> any {
  if ($ssh_args | is-empty) {
    return (^ssh)
  }
  mut session = {ssh_term: "", ssh_opts: []}
  let shell_features = $env.GHOSTTY_SHELL_FEATURES | split row ','

  if "ssh-env" in $shell_features {
    $session = set_ssh_env
  }
  if "ssh-terminfo" in $shell_features {
    $session = set_ssh_terminfo $session.ssh_opts $ssh_args
  }

  let ssh_parts = $session.ssh_opts ++ $ssh_args
  with-env {TERM: $session.ssh_term} {
    ^ssh ...$ssh_parts
  }
}

# Removes Ghostty's data directory from XDG_DATA_DIRS 
$env.XDG_DATA_DIRS = (
  $env.XDG_DATA_DIRS
  | split row ':'
  | where {|path| $path != $env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR }
  | str join ':'
)
