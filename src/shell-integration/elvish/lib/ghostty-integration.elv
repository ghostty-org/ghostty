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

  if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) or (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-terminfo) {

    if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-terminfo) {
      var _CACHE = $E:GHOSTTY_RESOURCES_DIR/shell-integration/shared/ghostty-ssh-cache
    }

    # SSH wrapper
    fn ssh {|@args|
      var env = []
      var opts = []
      var ctrl = []

      # Set up env vars first so terminfo installation inherits them
      if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) {
        var vars = [
          COLORTERM=truecolor
          TERM_PROGRAM=ghostty
        ]
        if (not-eq $E:TERM_PROGRAM_VERSION '') {
          set vars = [$@vars TERM_PROGRAM_VERSION=$E:TERM_PROGRAM_VERSION]
        }

        for v $vars {
          set-env (str:split = $v | take 1) (str:split = $v | drop 1 | str:join =)
          var varname = (str:split = $v | take 1)
          set opts = [$@opts -o 'SendEnv '$varname -o 'SetEnv '$v]
        }
      }

      # Install terminfo if needed, reuse control connection for main session
      if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-terminfo) {
        # Get target
        var target = ''
        try {
          set target = (e:ssh -G $@args 2>/dev/null | e:awk '/^(user|hostname) /{print $2}' | e:paste -sd'@')
        } catch { }

        if (and (not-eq $target '') ($_CACHE chk $target)) {
          set env = [$@env TERM=xterm-ghostty]
        } elif (has-external infocmp) {
          var tinfo = ''
          try {
            set tinfo = (e:infocmp -x xterm-ghostty 2>/dev/null)
          } catch {
            echo "Warning: xterm-ghostty terminfo not found locally." >&2
          }

          if (not-eq $tinfo '') {
            echo "Setting up Ghostty terminfo on remote host..." >&2
            var cpath = '/tmp/ghostty-ssh-'$E:USER'-'(randint 0 32767)'-'(date +%s)
            var result = (echo $tinfo | e:ssh $@opts -o ControlMaster=yes -o ControlPath=$cpath -o ControlPersist=60s $@args '
              infocmp xterm-ghostty >/dev/null 2>&1 && echo OK && exit
              command -v tic >/dev/null 2>&1 || { echo NO_TIC; exit 1; }
              mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && echo OK || echo FAIL
            ')
 
            if (eq $result OK) {
              echo "Terminfo setup complete." >&2
              if (not-eq $target '') { $_CACHE add $target }
              set env = [$@env TERM=xterm-ghostty]
              set ctrl = [$@ctrl -o ControlPath=$cpath]
            } else {
              echo "Warning: Failed to install terminfo." >&2
            }
          }
        } else {
          echo "Warning: infocmp not found locally. Terminfo installation unavailable." >&2
        }
      }

      # Fallback TERM only if terminfo didn't set it
      if (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-env) {
        if (and (eq $E:TERM xterm-ghostty) (not (str:contains (str:join ' ' $env) 'TERM='))) {
          set env = [$@env TERM=xterm-256color]
        }
      }

      # Execute
      if (> (count $env) 0) {
        e:env $@env e:ssh $@opts $@ctrl $@args
      } else {
        e:ssh $@opts $@ctrl $@args
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
