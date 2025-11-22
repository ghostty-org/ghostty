# Enables SSH environment variable compatibility.
# Converts TERM from xterm-ghostty to xterm-256color
# and propagates COLORTERM, TERM_PROGRAM, and TERM_PROGRAM_VERSION
# check your sshd_config on remote host to see if these variables are accepted
def set_ssh_env []: nothing -> record<ssh_term: string, ssh_opts: list<string>> {
    return {ssh_term: "xterm-256color", ssh_opts: ["-o", "SetEnv COLORTERM=truecolor", "-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]}
}

# Enables automatic terminfo installation on remote hosts.
# Attempts to install Ghostty's terminfo entry using infocmp and tic when
# connecting to hosts that lack it. 
# Requires infocmp to be available locally and tic to be available on remote hosts.
# Caches installations to avoid repeat installations.
def set_ssh_terminfo [ssh_opts: list<string>, ssh_args: list<string>] {
  mut ssh_opts = $ssh_opts
  let ssh_cfg = ^ssh -G ...($ssh_args)
    | lines 
    | split column -n 2 " " key value
    | where key == "user" or key == "hostname"
    | transpose -r
    | into record
  let ssh_user = $ssh_cfg.user
  let ssh_hostname = $ssh_cfg.hostname
  let ssh_id = $"($ssh_user)@($ssh_hostname)"
  let ghostty_bin = $env.GHOSTTY_BIN_DIR + "/ghostty"
  let check_cache_cmd = ["+ssh-cache", $"--host=($ssh_id)"]

  let is_cached = (
    ^$ghostty_bin ...$check_cache_cmd
    | complete
    | get exit_code
    | $in == 0
  )

  if not $is_cached {
    let ssh_opts_copy = $ssh_opts
    let terminfo_data = try {infocmp -0 -x xterm-ghostty} catch {
      print "Warning: Could not generate terminfo data."
      return {ssh_term: "xterm-256color", ssh_opts: $ssh_opts_copy}
    }

    print $"Setting up xterm-ghostty terminfo on ($ssh_hostname)..."

    let ctrl_dir = try {
      mktemp -td $"ghostty-ssh-($ssh_user).XXXXXX"
    } catch {
      $"/tmp/ghostty-ssh-($ssh_user).($nu.pid)"
    }

    let ctrl_path = $"($ctrl_dir)/socket"

    let master_parts = $ssh_opts ++ ["-o", "ControlMaster=yes", "-o", $"ControlPath=($ctrl_path)", "-o", "ControlPersist=60s"] ++ $ssh_args

    let infocmp_cmd = $master_parts ++ ["infocmp", "xterm-ghostty"]

    let terminfo_present = (
      ^ssh ...$infocmp_cmd
      | complete
      | get exit_code
      | $in == 0
    )

    if (not $terminfo_present) {
      let install_terminfo_cmd = $master_parts ++ ["mkdir", "-p", "~/.terminfo", "&&", "tic", "-x", "-"]

      ($terminfo_data | ^ssh ...$install_terminfo_cmd) | complete | get exit_code | if $in != 0 {
        print "Warning: Failed to install terminfo."
        return {ssh_term: "xterm-256color", ssh_opts: $ssh_opts}
      } 
      let state_dir = try { $env.XDG_STATE_HOME } catch { $env.HOME | path join ".local/state" }
      let ghostty_state_dir = $state_dir | path join "ghostty"

      let cache_add_cmd = ["+ssh-cache", $"--add=($ssh_id)"]

      # Bug?: If I dont add TMPDIR, it complains about renameacrossmountpoints
      with-env { TMPDIR: $ghostty_state_dir } {
        ^$ghostty_bin ...$cache_add_cmd o+e>| ignore
      }
    }
    $ssh_opts ++= ["-o", $"ControlPath=($ctrl_path)"]
  }

  return {ssh_term: "xterm-ghostty", ssh_opts: $ssh_opts}
}

# SSH Integration
export def --wrapped ssh [...ssh_args: string] {
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
  with-env { TERM: $session.ssh_term } {
    ^ssh ...$ssh_parts
  }
}

# Removes Ghostty's data directory from XDG_DATA_DIRS 
let ghostty_data_dir = $env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR 
$env.XDG_DATA_DIRS = $env.XDG_DATA_DIRS
  | split row ':'
  | where (
  | $it !~ $ghostty_data_dir
  )
  | str join ':'
