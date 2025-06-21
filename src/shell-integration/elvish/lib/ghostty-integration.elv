{
  fn restore-xdg-dirs {
    use str
    var integration-dir = $E:GHOSTTY_SHELL_INTEGRATION_XDG_DIR
    var xdg-dirs = [(str:split ':' $E:XDG_DATA_DIRS)]
    var len = (count $xdg-dirs)

    var index = $nil
    range $len | each {|dir-index|
      if (eq $xdg-dirs[$dir-index] $integration-dir) {
        set index = $dir-index
        break
      }
    }
    if (eq $nil $index) { return } # will appear as an error

    if (== 0 $index) {
      set xdg-dirs = $xdg-dirs[1..]
    } elif (== (- $len 1) $index) {
      set xdg-dirs = $xdg-dirs[0..(- $len 1)]
    } else {
      # no builtin function for this : )
      set xdg-dirs = [ (take $index $xdg-dirs) (drop (+ 1 $index) $xdg-dirs) ]
    }

    if (== 0 (count $xdg-dirs)) {
      unset-env XDG_DATA_DIRS
    } else {
      set-env XDG_DATA_DIRS (str:join ':' $xdg-dirs)
    }
    unset-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR
  }
  if (and (has-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR) (has-env XDG_DATA_DIRS)) {
    restore-xdg-dirs
  }
}

{
  use str

  # helper used by `mark-*` functions
  fn set-prompt-state {|new| set-env __ghostty_prompt_state $new }

  fn mark-prompt-start {
    if (not-eq prompt-start (constantly $E:__ghostty_prompt_state)) {
      printf "\e]133;D\a"
    }
    set-prompt-state 'prompt-start'
    printf "\e]133;A\a"
  }

  fn mark-output-start {|_|
    set-prompt-state 'pre-exec'
    printf "\e]133;C\a"
  }

  fn mark-output-end {|cmd-info|
    set-prompt-state 'post-exec'

    var exit-status = 0

    # in case of error: retrieve exit status,
    # unless does not exist (= builtin function failure), then default to 1
    if (not-eq $nil $cmd-info[error]) {
      set exit-status = 1

      if (has-key $cmd-info[error] reason) {
        if (has-key $cmd-info[error][reason] exit-status) {
          set exit-status = $cmd-info[error][reason][exit-status]
        }
      }
    }

    printf "\e]133;D;"$exit-status"\a"
  }

  fn report-pwd {
    use platform
    printf "\e]7;kitty-shell-cwd://%s%s\a" (platform:hostname) $pwd
  }

  fn sudo-with-terminfo {|@args|
    var sudoedit = $false
    for arg $args {
      use str
      if (str:has-prefix $arg -) {
        if (has-value [e -edit] $arg[1..]) {
          set sudoedit = $true
          break
        }
        continue
      }

      if (not (has-value $arg =)) { break }
    }

    if (not $sudoedit) { set args = [ TERMINFO=$E:TERMINFO $@args ] }
    (external sudo) $@args
  }

  # SSH Integration
  # Cache file for tracking hosts with terminfo installed
  var ghostty-cache-file = (if (has-env GHOSTTY_RESOURCES_DIR) { put $E:GHOSTTY_RESOURCES_DIR"/terminfo_hosts" } else { put $E:HOME"/.config/ghostty/terminfo_hosts" })

  # Extract target host from SSH arguments
  fn ghostty-get-ssh-target {|@args|
    var target = ""
    var skip-next = $false

    for arg $args {
      if (eq $skip-next $true) {
        set skip-next = $false
        continue
      }

      # Skip flags that take arguments
      if (re:match '^-[bcDEeFIiJLlmOopQRSWw]$' $arg) {
        set skip-next = $true
        continue
      }

      # Skip other flags
      if (re:match '^-' $arg) {
        continue
      }

      # This should be the target
      set target = $arg
      break
    }

    put $target
  }

  # Check if host has terminfo installed
  fn ghostty-host-has-terminfo {|target|
    and (path:is-regular $ghostty-cache-file) ?(grep -qFx $target $ghostty-cache-file 2>/dev/null)
  }

  # Add host to terminfo cache
  fn ghostty-cache-host {|target|
    var cache-dir = (path:dir $ghostty-cache-file)

    # Create cache directory if needed
    if (not (path:is-dir $cache-dir)) {
      mkdir -p $cache-dir
    }

    # Atomic write to cache file
    var temp-file = $ghostty-cache-file".tmp"

    {
      if (path:is-regular $ghostty-cache-file) {
        cat $ghostty-cache-file
      }
      echo $target
    } | sort -u > $temp-file

    mv $temp-file $ghostty-cache-file

    # Secure permissions
    ?chmod 600 $ghostty-cache-file 2>/dev/null
  }

  fn ssh-with-ghostty-integration {|@args|
    if (has-env GHOSTTY_SSH_INTEGRATION) {
      if (eq "term-only" $E:GHOSTTY_SSH_INTEGRATION) {
        ssh-term-only $@args
      } elif (eq "basic" $E:GHOSTTY_SSH_INTEGRATION) {
        ssh-basic $@args  
      } elif (eq "full" $E:GHOSTTY_SSH_INTEGRATION) {
        ssh-full $@args
      } else {
        # Unknown level, fall back to basic
        ssh-basic $@args
      }
    } else {
      (external ssh) $@args
    }
  }

  fn ssh-term-only {|@args|
    # Level: term-only - Just fix TERM compatibility
    if (eq "xterm-ghostty" $E:TERM) {
      (external env) TERM=xterm-256color ssh $@args
    } else {
      (external ssh) $@args
    }
  }

  fn ssh-basic {|@args|
    # Level: basic - TERM fix + environment variable propagation
    var env-vars = []

    # Fix TERM compatibility
    if (eq "xterm-ghostty" $E:TERM) {
      set env-vars = (conj $env-vars TERM=xterm-256color)
    }

    # Propagate Ghostty shell integration environment variables
    if (not-eq "" $E:GHOSTTY_SHELL_FEATURES) {
      set env-vars = (conj $env-vars GHOSTTY_SHELL_FEATURES=$E:GHOSTTY_SHELL_FEATURES)
    }

    # Execute with environment variables if any were set
    if (> (count $env-vars) 0) {
      (external env) $@env-vars ssh $@args
    } else {
      (external ssh) $@args
    }
  }

  fn ssh-full {|@args|
    var target = (ghostty-get-ssh-target $@args)

    # Check if we already know this host has terminfo
    if (and (not-eq "" $target) (ghostty-host-has-terminfo $target)) {
      # Direct connection with xterm-ghostty
      var env-vars = [TERM=xterm-ghostty]

      # Propagate Ghostty shell integration environment variables
      if (not-eq "" $E:GHOSTTY_SHELL_FEATURES) {
        set env-vars = (conj $env-vars GHOSTTY_SHELL_FEATURES=$E:GHOSTTY_SHELL_FEATURES)
      }

      (external env) $@env-vars ssh $@args
      return
    }

    # Full integration: Install terminfo if needed
    if (has-external infocmp) {
      try {
        # Install terminfo only if needed
        infocmp -x xterm-ghostty 2>/dev/null | (external ssh) $@args '
          if ! infocmp xterm-ghostty >/dev/null 2>&1; then
            echo "Installing Ghostty terminfo..." >&2
            tic -x - 2>/dev/null
          fi
        '
        echo "Connecting with full Ghostty support..." >&2

        # Cache this host for future connections
        if (not-eq "" $target) {
          ghostty-cache-host $target
        }

        # Connect with xterm-ghostty since terminfo is available
        var env-vars = [TERM=xterm-ghostty]

        # Propagate Ghostty shell integration environment variables
        if (not-eq "" $E:GHOSTTY_SHELL_FEATURES) {
          set env-vars = (conj $env-vars GHOSTTY_SHELL_FEATURES=$E:GHOSTTY_SHELL_FEATURES)
        }

        # Normal SSH connection with Ghostty terminfo available
        (external env) $@env-vars ssh $@args
        return
      } catch e {
        echo "Terminfo installation failed. Using basic integration." >&2
      }
    }

    # Fallback to basic integration
    ssh-basic $@args
  }

  # Register SSH integration if enabled
  if (and (has-env GHOSTTY_SSH_INTEGRATION) (has-external ssh)) {
    edit:add-var ssh~ $ssh-with-ghostty-integration~
  } 

  defer {
    mark-prompt-start
    report-pwd
  }

  set edit:before-readline = (conj $edit:before-readline $mark-prompt-start~)
  set edit:after-readline  = (conj $edit:after-readline $mark-output-start~)
  set edit:after-command   = (conj $edit:after-command $mark-output-end~)

  var features = [(str:split ',' $E:GHOSTTY_SHELL_FEATURES)]

  if (has-value $features title) {
    set after-chdir = (conj $after-chdir {|_| report-pwd })
  }
  if (has-value $features cursor) {
    fn beam  { printf "\e[5 q" }
    fn block { printf "\e[0 q" }
    set edit:before-readline = (conj $edit:before-readline $beam~)
    set edit:after-readline  = (conj $edit:after-readline {|_| block })
  }
  if (and (has-value $features sudo) (not-eq "" $E:TERMINFO) (has-external sudo)) {
    edit:add-var sudo~ $sudo-with-terminfo~
  }
}
