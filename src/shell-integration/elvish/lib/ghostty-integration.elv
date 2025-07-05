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
  use str

  if (or (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-terminfo)) {
      fn ssh {|@args|
          var ssh-env = []
          var ssh-opts = []
          var ssh-exported-vars = []

          # Configure environment variables for remote session
          if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) {
              set ssh-opts = [$@ssh-opts -o "SetEnv COLORTERM=truecolor"]

              if (has-env TERM_PROGRAM) {
                  set ssh-exported-vars = [$@ssh-exported-vars "TERM_PROGRAM="$E:TERM_PROGRAM]
              } else {
                  set ssh-exported-vars = [$@ssh-exported-vars "TERM_PROGRAM"]
              }
              set-env TERM_PROGRAM ghostty
              set ssh-opts = [$@ssh-opts -o "SendEnv TERM_PROGRAM"]

              if (has-env TERM_PROGRAM_VERSION) {
                  if (has-env TERM_PROGRAM_VERSION) {
                      set ssh-exported-vars = [$@ssh-exported-vars "TERM_PROGRAM_VERSION="$E:TERM_PROGRAM_VERSION]
                  } else {
                      set ssh-exported-vars = [$@ssh-exported-vars "TERM_PROGRAM_VERSION"]
                  }
                  set ssh-opts = [$@ssh-opts -o "SendEnv TERM_PROGRAM_VERSION"]
              }

              set ssh-env = [
                  "COLORTERM=truecolor"
                  "TERM_PROGRAM=ghostty"
              ]
              if (has-env TERM_PROGRAM_VERSION) {
                  set ssh-env = [$@ssh-env "TERM_PROGRAM_VERSION="$E:TERM_PROGRAM_VERSION]
              }
          }

          # Install terminfo on remote host if needed
          if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-terminfo) {
              var ssh-config = ""
              try {
                  set ssh-config = (external ssh -G $@args 2>/dev/null | slurp)
              } catch {
                  set ssh-config = ""
              }

              var ssh-user = ""
              var ssh-hostname = ""

              for line (str:split "\n" $ssh-config) {
                  var parts = (str:split " " $line)
                  if (> (count $parts) 1) {
                      if (eq $parts[0] user) {
                          set ssh-user = $parts[1]
                      } elif (eq $parts[0] hostname) {
                          set ssh-hostname = $parts[1]
                      }
                      if (and (not-eq $ssh-user "") (not-eq $ssh-hostname "")) {
                          break
                      }
                  }
              }

              var ssh-target = $ssh-user"@"$ssh-hostname

              if (not-eq $ssh-hostname "") {
                  # Check if terminfo is already cached
                  var ssh-cache-check-success = $false
                  try {
                      external ghostty +ssh-cache --host=$ssh-target >/dev/null 2>&1
                      set ssh-cache-check-success = $true
                  } catch {
                      # cache check failed
                  }

                  if $ssh-cache-check-success {
                      set ssh-env = [$@ssh-env TERM=xterm-ghostty]
                  } else {
                      try {
                          external infocmp --help >/dev/null 2>&1

                          try {
                              external base64 --help >/dev/null 2>&1

                              # Generate terminfo data (BSD base64 compatibility)
                              var ssh-terminfo = ""
                              var ssh-base64-decode-cmd = ""
                              try {
                                  var base64-help = (external base64 --help 2>&1 | slurp)
                                  if (str:contains $base64-help GNU) {
                                      set ssh-base64-decode-cmd = "base64 -d"
                                      set ssh-terminfo = (external infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | external base64 -w0 2>/dev/null | slurp)
                                  } else {
                                      set ssh-base64-decode-cmd = "base64 -D"
                                      set ssh-terminfo = (external infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | external base64 2>/dev/null | external tr -d '\n' | slurp)
                                  }
                              } catch {
                                  set ssh-terminfo = ""
                              }

                              if (not-eq $ssh-terminfo "") {
                                  echo "Setting up Ghostty terminfo on "$ssh-hostname"..." >&2
                                  var ssh-cpath-dir = ""
                                  try {
                                      set ssh-cpath-dir = (external mktemp -d "/tmp/ghostty-ssh-"$ssh-user".XXXXXX" 2>/dev/null | slurp)
                                  } catch {
                                      set ssh-cpath-dir = "/tmp/ghostty-ssh-"$ssh-user"."(randint 10000 99999)
                                  }
                                  var ssh-cpath = $ssh-cpath-dir"/socket"

                                  var terminfo-install-success = $false
                                  try {
                                      echo $ssh-terminfo | external sh -c $ssh-base64-decode-cmd | external ssh $@ssh-opts -o ControlMaster=yes -o ControlPath=$ssh-cpath -o ControlPersist=60s $@args '
                                          infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                                          command -v tic >/dev/null 2>&1 || exit 1
                                          mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                                          exit 1
                                      ' >/dev/null 2>&1
                                      set terminfo-install-success = $true
                                  } catch {
                                      set terminfo-install-success = $false
                                  }

                                  if $terminfo-install-success {
                                      echo "Terminfo setup complete on "$ssh-hostname"." >&2
                                      set ssh-env = [$@ssh-env TERM=xterm-ghostty]
                                      set ssh-opts = [$@ssh-opts -o ControlPath=$ssh-cpath]

                                      # Cache successful installation
                                      if (and (not-eq $ssh-target "") (has-external ghostty)) {
                                          external ghostty +ssh-cache --add=$ssh-target >/dev/null 2>&1 &
                                      }
                                  } else {
                                      echo "Warning: Failed to install terminfo." >&2
                                      set ssh-env = [$@ssh-env TERM=xterm-256color]
                                  }
                              } else {
                                  echo "Warning: Could not generate terminfo data." >&2
                                  set ssh-env = [$@ssh-env TERM=xterm-256color]
                              }
                          } catch {
                              echo "Warning: base64 command not available for terminfo installation." >&2
                              set ssh-env = [$@ssh-env TERM=xterm-256color]
                          }
                      } catch {
                          echo "Warning: ghostty command not available for cache management." >&2
                          set ssh-env = [$@ssh-env TERM=xterm-256color]
                      }
                  }
              } else {
                  if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) {
                      set ssh-env = [$@ssh-env TERM=xterm-256color]
                  }
              }
          }

          # Execute SSH with environment handling
          var ssh-term-override = ""
          for ssh-v $ssh-env {
              if (str:has-prefix $ssh-v TERM=) {
                  set ssh-term-override = (str:trim-prefix $ssh-v TERM=)
                  break
              }
          }

          if (and (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) (eq $ssh-term-override "")) {
              set ssh-env = [$@ssh-env TERM=xterm-256color]
              set ssh-term-override = xterm-256color
          }

          var ssh-ret = 0
          if (not-eq $ssh-term-override "") {
              var ssh-original-term = $E:TERM
              set-env TERM $ssh-term-override
              try {
                  external ssh $@ssh-opts $@args
              } catch e {
                  set ssh-ret = $e[reason][exit-status]
              }
              set-env TERM $ssh-original-term
          } else {
              try {
                  external ssh $@ssh-opts $@args
              } catch e {
                  set ssh-ret = $e[reason][exit-status]
              }
          }

          # Restore original environment variables
          if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) {
              for ssh-v $ssh-exported-vars {
                  if (str:contains $ssh-v =) {
                      var ssh-var-parts = (str:split &max=2 = $ssh-v)
                      set-env $ssh-var-parts[0] $ssh-var-parts[1]
                  } else {
                      unset-env $ssh-v
                  }
              }
          }

          if (not-eq $ssh-ret 0) {
              fail ssh-failed
          }
      }
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
