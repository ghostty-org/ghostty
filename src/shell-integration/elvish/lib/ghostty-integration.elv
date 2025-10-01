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

  # List of enabled shell integration features
  var features = [(str:split ',' $E:GHOSTTY_SHELL_FEATURES)]

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

  fn ssh-integration {|@args|
    var ssh-term = "xterm-256color"
    var ssh-opts = []

    # Configure environment variables for remote session
    if (has-value $features ssh-env) {
      set ssh-opts = (conj $ssh-opts ^
        -o "SetEnv COLORTERM=truecolor" ^
        -o "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION")
    }

    if (has-value $features ssh-terminfo) {
      var ssh-user = ""
      var ssh-hostname = ""

      # Parse ssh config
      for line [((external ssh) -G $@args)] {
        var parts = [(str:fields $line)]
        if (> (count $parts) 1) {
          var ssh-key = $parts[0]
          var ssh-value = $parts[1]
          if (eq $ssh-key user) {
            set ssh-user = $ssh-value
          } elif (eq $ssh-key hostname) {
            set ssh-hostname = $ssh-value
          }
          if (and (not-eq $ssh-user "") (not-eq $ssh-hostname "")) {
            break
          }
        }
      }

      if (not-eq $ssh-hostname "") {
        var ghostty = $E:GHOSTTY_BIN_DIR/"ghostty"
        var ssh-target = $ssh-user"@"$ssh-hostname

        # Check if terminfo is already cached
        if (bool ?($ghostty +ssh-cache --host=$ssh-target)) {
          set ssh-term = "xterm-ghostty"
        } elif (has-external infocmp) {
          var ssh-terminfo = ((external infocmp) -0 -x xterm-ghostty 2>/dev/null | slurp)

          if (not-eq $ssh-terminfo "") {
            echo "Setting up xterm-ghostty terminfo on "$ssh-hostname"..." >&2

            use os
            var ssh-cpath-dir = (os:temp-dir "ghostty-ssh-"$ssh-user".*")
            var ssh-cpath = $ssh-cpath-dir"/socket"

            if (bool ?(echo $ssh-terminfo | (external ssh) $@ssh-opts -o ControlMaster=yes -o ControlPath=$ssh-cpath -o ControlPersist=60s $@args '
                  infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                  command -v tic >/dev/null 2>&1 || exit 1
                  mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                  exit 1
                ' 2>/dev/null)) {
              set ssh-term = "xterm-ghostty"
              set ssh-opts = (conj $ssh-opts -o ControlPath=$ssh-cpath)

              # Cache successful installation
              $ghostty +ssh-cache --add=$ssh-target >/dev/null
            } else {
              echo "Warning: Failed to install terminfo." >&2
            }
          } else {
            echo "Warning: Could not generate terminfo data." >&2
          }
        } else {
          echo "Warning: ghostty command not available for cache management." >&2
        }
      }
    }

    with [E:TERM = $ssh-term] {
      (external ssh) $@ssh-opts $@args
    }
  }

  defer {
    mark-prompt-start
    report-pwd
  }

  set edit:before-readline = (conj $edit:before-readline $mark-prompt-start~)
  set edit:after-readline  = (conj $edit:after-readline $mark-output-start~)
  set edit:after-command   = (conj $edit:after-command $mark-output-end~)

  if (has-value $features title) {
    set after-chdir = (conj $after-chdir {|_| report-pwd })
  }
  if (has-value $features cursor) {
    fn beam  { printf "\e[5 q" }
    fn block { printf "\e[0 q" }
    set edit:before-readline = (conj $edit:before-readline $beam~)
    set edit:after-readline  = (conj $edit:after-readline {|_| block })
  }
  if (and (has-value $features path) (has-env GHOSTTY_BIN_DIR)) {
    if (not (has-value $paths $E:GHOSTTY_BIN_DIR)) {
        set paths = [$@paths $E:GHOSTTY_BIN_DIR]
    }
  }
  if (and (has-value $features sudo) (not-eq "" $E:TERMINFO) (has-external sudo)) {
    edit:add-var sudo~ $sudo-with-terminfo~
  }
  if (and (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-) (has-external ssh)) {
    edit:add-var ssh~ $ssh-integration~
  }
}
