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
  let ssh_cfg = (
    run-external "ssh" "-G" ...($ssh_args)
    | lines 
    | each {|e| if $e =~ '\buser\b' or $e =~ '\bhostname\b' {split row ' '}}
  )
  let ssh_user = $ssh_cfg.0.1
  let ssh_hostname = $ssh_cfg.1.1
  let ssh_id = $"($ssh_user)@($ssh_hostname)"
  let ghostty_bin = $env.GHOSTTY_BIN_DIR + "/ghostty"
  let check_cache_cmd = [$ghostty_bin, "+ssh-cache", $"--host=($ssh_id)"]

  let is_cached = (
    run-external ...$check_cache_cmd
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

    let tmp_dir = $"/tmp/ghostty-ssh-($ssh_user).XXXXXX"
    let mktemp_cmd = ["mktemp", "-d", $tmp_dir]
    let ctrl_dir = try {
        run-external ...$mktemp_cmd
        | str trim          
    } catch {
        $"/tmp/ghostty-ssh-($ssh_user).($nu.pid)"
    }
    let ctrl_path = $"($ctrl_dir)/socket"

    let master_parts = $ssh_opts ++ ["-o", "ControlMaster=yes", "-o", $"ControlPath=($ctrl_path)", "-o", "ControlPersist=60s"] ++ $ssh_args

    let infocmp_cmd = ["ssh"] ++ $master_parts ++ ["infocmp", "xterm-ghostty"]

    let terminfo_present = (
      run-external ...$infocmp_cmd
      | complete
      | get exit_code
      | $in == 0
    )

    if (not $terminfo_present) {
      let install_terminfo_cmd = ["ssh"] ++ $master_parts ++ ["mkdir", "-p", "~/.terminfo", "&&", "tic", "-x", "-"]

      ($terminfo_data | run-external ...$install_terminfo_cmd) | complete | get exit_code | if $in != 0 {
        print "Warning: Failed to install terminfo."
        return {ssh_term: "xterm-256color", ssh_opts: $ssh_opts}
      } 
      let state_dir = try { $env.XDG_STATE_HOME } catch { $env.HOME | path join ".local/state" }
      let ghostty_state_dir = $state_dir | path join "ghostty"

      let cache_add_cmd = [$ghostty_bin, "+ssh-cache", $"--add=($ssh_id)"]
      # Bug?: If I dont add TMPDIR, it complains about renameacrossmountpoints
      with-env { TMPDIR: $ghostty_state_dir } {
        run-external ...$cache_add_cmd o+e>| ignore
      }
    }
    $ssh_opts ++= ["-o", $"ControlPath=($ctrl_path)"]
  }

  return {ssh_term: "xterm-ghostty", ssh_opts: $ssh_opts}
}

# SSH Integration
export def --wrapped ssh [...ssh_args: string] {
  if ($ssh_args | is-empty) {
    run-external "ssh"
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
      run-external "ssh" ...$ssh_parts
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
