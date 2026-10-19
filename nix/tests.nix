{
  self,
  system,
  nixpkgs,
  home-manager,
  ...
}: let
  nixos-version = nixpkgs.lib.trivial.release;

  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      self.overlays.debug
    ];
  };

  pink_value = "#FF0087";

  color_test = ''
    import tempfile
    import subprocess

    def check_for_pink(final=False) -> bool:
        with tempfile.NamedTemporaryFile() as tmpin:
            machine.send_monitor_command("screendump {}".format(tmpin.name))

            cmd = 'convert {} -define histogram:unique-colors=true -format "%c" histogram:info:'.format(
                tmpin.name
            )
            ret = subprocess.run(cmd, shell=True, capture_output=True)
            if ret.returncode != 0:
                raise Exception(
                    "image analysis failed with exit code {}".format(ret.returncode)
                )

            text = ret.stdout.decode("utf-8")
            return "${pink_value}" in text
  '';

  mkNodeGnome = {
    config,
    pkgs,
    settings,
    sshPort ? null,
    ...
  }: {
    imports = [
      ./vm/wayland-gnome.nix
      settings
    ];

    virtualisation = {
      forwardPorts = pkgs.lib.optionals (sshPort != null) [
        {
          from = "host";
          host.port = sshPort;
          guest.port = 22;
        }
      ];

      vmVariant = {
        virtualisation.host.pkgs = pkgs;
      };
    };

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "yes";
        PermitEmptyPasswords = "yes";
      };
    };

    security.pam.services.sshd.allowNullPassword = true;

    users.groups.ghostty = {
      gid = 1000;
    };

    users.users.ghostty = {
      uid = 1000;
    };

    home-manager = {
      users = {
        ghostty = {
          home = {
            username = config.users.users.ghostty.name;
            homeDirectory = config.users.users.ghostty.home;
            stateVersion = nixos-version;
          };
          programs.ssh = {
            enable = true;
            enableDefaultConfig = false;
            extraOptionOverrides = {
              StrictHostKeyChecking = "accept-new";
              UserKnownHostsFile = "/dev/null";
            };
          };
        };
      };
    };

    system.stateVersion = nixos-version;
  };

  mkTestGnome = {
    name,
    settings,
    testScript,
    ocr ? false,
  }:
    pkgs.testers.runNixOSTest {
      name = name;

      enableOCR = ocr;

      extraBaseModules = {
        imports = [
          home-manager.nixosModules.home-manager
        ];
      };

      nodes = {
        machine = {
          config,
          pkgs,
          ...
        }:
          mkNodeGnome {
            inherit config pkgs settings;
            sshPort = 2222;
          };
      };

      testScript = testScript;
    };
in {
  basic-version-check = pkgs.testers.runNixOSTest {
    name = "basic-version-check";
    nodes = {
      machine = {pkgs, ...}: {
        users.groups.ghostty = {};
        users.users.ghostty = {
          isNormalUser = true;
          group = "ghostty";
          extraGroups = ["wheel"];
          hashedPassword = "";
          packages = [
            pkgs.ghostty
          ];
        };
      };
    };
    testScript = {...}: ''
      machine.succeed("su - ghostty -c 'ghostty +version'")
    '';
  };

  basic-window-check-gnome = mkTestGnome {
    name = "basic-window-check-gnome";
    settings = {
      home-manager.users.ghostty = {
        xdg.configFile = {
          "ghostty/config".text = ''
            background = ${pink_value}
          '';
        };
      };
    };
    ocr = true;
    testScript = {nodes, ...}: let
      user = nodes.machine.users.users.ghostty;
      bus_path = "/run/user/${toString user.uid}/bus";
      bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}";
      gdbus = "${bus} gdbus";
      ghostty = "${bus} ghostty";
      su = command: "su - ${user.name} -c '${command}'";
      gseval = "call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval";
      wm_class = su "${gdbus} ${gseval} global.display.focus_window.wm_class";
    in ''
      ${color_test}

      with subtest("wait for x"):
          start_all()
          machine.wait_for_x()

      machine.wait_for_file("${bus_path}")

      with subtest("GNOME Shell allows window inspection"):
          machine.wait_until_succeeds("${su "${gdbus} ${gseval} true"}")
          assert machine.succeed("${su "${gdbus} ${gseval} true"}").strip() == "(true, 'true')"

      with subtest("Ensuring no pink is present without the terminal."):
          assert (
              check_for_pink() == False
          ), "Pink was present on the screen before we even launched a terminal!"

      machine.systemctl("enable app-com.mitchellh.ghostty-debug.service", user="${user.name}")
      machine.succeed("${su "${ghostty} +new-window"}")
      machine.wait_until_succeeds("${wm_class} | grep -q 'com.mitchellh.ghostty-debug'")

      machine.sleep(2)

      with subtest("Have the terminal display a color."):
          assert(
              check_for_pink() == True
          ), "Pink was not found on the screen!"

      machine.systemctl("stop app-com.mitchellh.ghostty-debug.service", user="${user.name}")
    '';
  };

  ssh-integration-test = pkgs.testers.runNixOSTest {
    name = "ssh-integration-test";
    extraBaseModules = {
      imports = [
        home-manager.nixosModules.home-manager
      ];
    };
    nodes = {
      server = {...}: {
        users.groups.ghostty = {};
        users.users.ghostty = {
          isNormalUser = true;
          group = "ghostty";
          extraGroups = ["wheel"];
          hashedPassword = "";
          packages = [];
        };
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "yes";
            PermitEmptyPasswords = "yes";
          };
        };
        security.pam.services.sshd.allowNullPassword = true;
      };
      client = {
        config,
        pkgs,
        ...
      }:
        mkNodeGnome {
          inherit config pkgs;
          settings = {
            home-manager.users.ghostty = {
              xdg.configFile = {
                "ghostty/config".text = let
                in ''
                  shell-integration-features = ssh-terminfo
                '';
              };
            };
          };
          sshPort = 2222;
        };
    };
    testScript = {nodes, ...}: let
      user = nodes.client.users.users.ghostty;
      bus_path = "/run/user/${toString user.uid}/bus";
      bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}";
      gdbus = "${bus} gdbus";
      ghostty = "${bus} ghostty";
      su = command: "su - ${user.name} -c '${command}'";
      gseval = "call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval";
      wm_class = su "${gdbus} ${gseval} global.display.focus_window.wm_class";
    in ''
      with subtest("Start server and wait for ssh to be ready."):
          server.start()
          server.wait_for_open_port(22)

      with subtest("Start client and wait for ghostty window."):
          client.start()
          client.wait_for_x()
          client.wait_for_file("${bus_path}")
          client.systemctl("enable app-com.mitchellh.ghostty-debug.service", user="${user.name}")
          client.succeed("${su "${ghostty} +new-window"}")
          client.wait_until_succeeds("${wm_class} | grep -q 'com.mitchellh.ghostty-debug'")

      with subtest("SSH from client to server and verify that the Ghostty terminfo is copied."):
          client.sleep(2)
          client.send_chars("ssh ghostty@server\n")
          server.wait_for_file("${user.home}/.terminfo/x/xterm-ghostty", timeout=30)
    '';
  };

  undo-check-gnome = mkTestGnome {
    name = "undo-check-gnome";
    settings = {
      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
      environment.sessionVariables = {
        LIBGL_ALWAYS_SOFTWARE = "1";
        GALLIUM_DRIVER = "llvmpipe";
      };
      home-manager.users.ghostty.xdg.configFile."ghostty/config".text = ''
        command = ${pkgs.bash}/bin/bash --noprofile --norc
        env = PROMPT_COMMAND=echo $$ > /tmp/undo-ready
        shell-integration = none
        confirm-close-surface = false
        undo-timeout = 60s
        keybind = ctrl+alt+t=new_tab
        keybind = ctrl+alt+w=close_tab:this
        keybind = ctrl+alt+s=new_split:right
        keybind = ctrl+alt+g=goto_split:left
        keybind = ctrl+alt+p=goto_split:previous
        keybind = ctrl+alt+y=redo
        keybind = ctrl+alt+k=quit
        keybind = ctrl+alt+u=undo
        keybind = ctrl+alt+1=goto_tab:1
        keybind = ctrl+alt+2=goto_tab:2
        keybind = ctrl+alt+3=goto_tab:3
        config-file = ?/tmp/undo-config
      '';
    };
    testScript = {nodes, ...}: let
      user = nodes.machine.users.users.ghostty;
      bus_path = "/run/user/${toString user.uid}/bus";
      bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}";
      su = command: "su - ${user.name} -c '${command}'";
      windows = su "${bus} gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval \"global.get_window_actors().filter(w => w.meta_window.wm_class === \\\"com.mitchellh.ghostty-debug\\\").length\"";
      title = su "${bus} gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval global.display.focus_window.title";
    in ''
      import shlex
      from datetime import timedelta

      def wait_windows(count: int) -> None:
          machine.wait_until_succeeds(${builtins.toJSON windows} + " | grep -q \"'" + str(count) + "'\"", timeout=timedelta(seconds=30))

      def open_window() -> None:
          machine.succeed("rm -f /tmp/undo-ready")
          machine.execute("${su "${bus} ghostty +new-window"}")
          wait_windows(1)
          machine.wait_for_file("/tmp/undo-ready", timeout=timedelta(seconds=30))
          machine.sleep(timedelta(seconds=1))

      def restart(config: str = "") -> None:
          machine.systemctl("stop app-com.mitchellh.ghostty-debug.service", user="${user.name}")
          machine.succeed("printf %s " + shlex.quote(config) + " > /tmp/undo-config")
          open_window()

      def configure(config: str) -> None:
          machine.succeed("printf %s " + shlex.quote(config) + " > /tmp/undo-config")
          machine.systemctl("reload app-com.mitchellh.ghostty-debug.service", user="${user.name}")

      def press(key: str) -> None:
          creates_session = key in ("ctrl-alt-s", "ctrl-alt-d", "ctrl-alt-t", "ctrl-alt-n")
          if creates_session:
              machine.succeed("rm -f /tmp/undo-ready")
          machine.send_key(key)
          if creates_session:
              machine.wait_for_file("/tmp/undo-ready", timeout=timedelta(seconds=30))
          machine.sleep(timedelta(seconds=1))

      def history(direction: str) -> None:
          command = "${bus} ${pkgs.glib.bin}/bin/gapplication action com.mitchellh.ghostty-debug " + direction
          machine.succeed("su - ${user.name} -c " + shlex.quote(command))
          machine.sleep(timedelta(seconds=1))

      def remember(name: str) -> str:
          path = "/tmp/undo-" + name
          machine.send_chars("echo $$ > " + path + "\n", delay=timedelta(milliseconds=100))
          machine.wait_until_succeeds("test -s " + path, timeout=timedelta(seconds=30))
          return str(int(machine.succeed("cat " + path)))

      def expect_session(pid: str) -> None:
          machine.succeed("rm -f /tmp/undo-current")
          machine.send_chars("echo $$ > /tmp/undo-current\n", delay=timedelta(milliseconds=100))
          machine.wait_until_succeeds("test -s /tmp/undo-current", timeout=timedelta(seconds=30))
          current = machine.succeed("cat /tmp/undo-current").strip()
          assert current == pid, f"expected shell {pid}, got {current}"

      def terminal_size() -> str:
          machine.succeed("rm -f /tmp/undo-size")
          machine.send_chars("stty size > /tmp/undo-size\n", delay=timedelta(milliseconds=100))
          machine.wait_until_succeeds("test -s /tmp/undo-size", timeout=timedelta(seconds=30))
          return machine.succeed("cat /tmp/undo-size").strip()

      start_all()
      machine.wait_for_x()
      machine.wait_for_file("${bus_path}")
      machine.systemctl("enable app-com.mitchellh.ghostty-debug.service", user="${user.name}")

      with subtest("tab undo restores its position"):
          restart()
          original = remember("original")
          press("ctrl-alt-t")
          middle = remember("middle")
          press("ctrl-alt-t")
          last = remember("last")
          assert len({original, middle, last}) == 3
          press("ctrl-alt-2")
          expect_session(middle)
          press("ctrl-alt-w")
          expect_session(last)
          press("ctrl-alt-u")
          expect_session(middle)
          press("ctrl-alt-1")
          expect_session(original)
          press("ctrl-alt-3")
          expect_session(last)

      with subtest("quit releases terminals retained by undo"):
          press("ctrl-alt-w")
          press("ctrl-alt-k")
          for pid in (original, middle, last):
              machine.wait_until_fails("kill -0 " + pid, timeout=timedelta(seconds=30))

      with subtest("undo keeps the app alive after its last tab closes"):
          restart()
          only = remember("only")
          press("ctrl-alt-w")
          wait_windows(0)
          machine.succeed("kill -0 " + only)
          machine.succeed("${su "${bus} systemctl --user is-active app-com.mitchellh.ghostty-debug.service"}")
          history("undo")
          wait_windows(1)
          expect_session(only)

      for kind, create, close in (
          ("tab", "ctrl-alt-t", "ctrl-alt-w"),
      ):
          for timeout in ("1s", "0"):
              with subtest(f"{kind} releases its terminal with timeout {timeout}"):
                  restart(f"undo-timeout = {timeout}\n")
                  anchor = remember(f"expiry-anchor-{kind}-{timeout}")
                  press(create)
                  expired = remember(f"expired-{kind}-{timeout}")
                  press(close)
                  expect_session(anchor)
                  machine.wait_until_fails("kill -0 " + expired, timeout=timedelta(seconds=30))
                  press("ctrl-alt-u")
                  expect_session(anchor)

          with subtest(f"undo restores a completed {kind} before older entries"):
              restart()
              anchor = remember("exit-anchor-" + kind)
              press("ctrl-alt-t")
              retained = remember("retained-" + kind)
              press("ctrl-alt-w")
              expect_session(anchor)
              press(create)
              exited = remember("exited-" + kind)
              machine.send_chars("printf '\\033]0;completed-" + kind + "\\007'\n", delay=timedelta(milliseconds=100))
              press(close)
              expect_session(anchor)
              machine.succeed("kill -HUP " + exited)
              machine.wait_until_fails("kill -0 " + exited, timeout=timedelta(seconds=30))
              press("ctrl-alt-u")
              machine.wait_until_succeeds(${builtins.toJSON title} + " | grep -q completed-" + kind, timeout=timedelta(seconds=30))
              press("ctrl-alt-u")
              expect_session(retained)

          with subtest(f"cancelled {kind} closure does not create undo history"):
              restart("confirm-close-surface = always\n")
              anchor = remember("confirm-anchor-" + kind)
              press(create)
              confirmed = remember("confirmed-" + kind)
              press(close)
              press("esc")
              expect_session(confirmed)
              press("ctrl-alt-u")
              expect_session(confirmed)
              press(close)
              press("tab")
              press("ret")
              expect_session(anchor)
              press("ctrl-alt-u")
              expect_session(confirmed)

      with subtest("entries expire independently"):
          restart("undo-timeout = 30s\n")
          anchor = remember("independent-anchor")
          press("ctrl-alt-t")
          older = remember("older")
          press("ctrl-alt-w")
          expect_session(anchor)
          configure("undo-timeout = 60s\n")
          press("ctrl-alt-t")
          newer = remember("newer")
          press("ctrl-alt-w")
          expect_session(anchor)
          machine.succeed("kill -0 " + older)
          machine.wait_until_fails("kill -0 " + older, timeout=timedelta(seconds=30))
          machine.succeed("kill -0 " + newer)
          press("ctrl-alt-u")
          expect_session(newer)
          press("ctrl-alt-u")
          expect_session(newer)

      for kind, create, close in (("tab", "ctrl-alt-t", "ctrl-alt-w"),):
          with subtest(f"redo closes a restored {kind} and remains undoable"):
              restart()
              anchor = remember("redo-anchor-" + kind)
              press(create)
              closed = remember("redo-closed-" + kind)
              press(close)
              for _ in range(3):
                  press("ctrl-alt-u")
                  expect_session(closed)
                  press("ctrl-alt-y")
                  expect_session(anchor)
                  machine.succeed("kill -0 " + closed)

      for kind, create, close in (("tab", "ctrl-alt-t", "ctrl-alt-w"),):
          for focused in (False, True):
              with subtest(f"closed {kind} preserves an exited split, focused {focused}"):
                  restart()
                  press(create)
                  surviving = remember(f"surviving-{kind}-{focused}")
                  press("ctrl-alt-s")
                  exited = remember(f"completed-{kind}-{focused}")
                  marker = f"completed-{kind}-{focused}"
                  machine.send_chars("printf '\\033]0;" + marker + "\\007'\n", delay=timedelta(milliseconds=100))
                  press("ctrl-alt-g")
                  size = terminal_size()
                  if focused:
                      press("ctrl-alt-p")
                  press(close)
                  wait_windows(1)
                  machine.succeed("kill -HUP " + exited)
                  machine.wait_until_fails("kill -0 " + exited, timeout=timedelta(seconds=30))
                  for _ in range(2):
                      press("ctrl-alt-u")
                      wait_windows(2 if kind == "window" else 1)
                      if focused:
                          machine.wait_until_succeeds(${builtins.toJSON title} + " | grep -q " + marker, timeout=timedelta(seconds=30))
                          press("ctrl-alt-g")
                      expect_session(surviving)
                      assert terminal_size() == size
                      press("ctrl-alt-p")
                      machine.wait_until_succeeds(${builtins.toJSON title} + " | grep -q " + marker, timeout=timedelta(seconds=30))
                      if not focused:
                          press("ctrl-alt-g")
                      press("ctrl-alt-y")
                      wait_windows(1)

      machine.systemctl("stop app-com.mitchellh.ghostty-debug.service", user="${user.name}")
    '';
  };

  # Regression test for the GTK audio-bell GStreamer thread leak. Each audio
  # bell used to allocate a fresh gtk.MediaFile (and thus a GStreamer pipeline
  # whose GL sink spawns gstglcontext/gldisplay-event threads that are never
  # joined), leaking ~4 threads per ring; the fix reuses one MediaFile per
  # surface. This rings many bells and asserts the GUI process thread count
  # stays bounded. Runs under GNOME on Wayland so it exercises the real path.
  bell-leak-check-gnome = mkTestGnome {
    name = "bell-leak-check-gnome";
    settings = {
      # The VM has no GPU, so GNOME and Ghostty render via llvmpipe. Give the
      # guest enough cores/RAM that software GL can bring up Ghostty's window
      # before the +new-window D-Bus activation times out, and force clean
      # software GL so mesa doesn't stall probing for absent hardware.
      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
      environment.sessionVariables = {
        LIBGL_ALWAYS_SOFTWARE = "1";
        GALLIUM_DRIVER = "llvmpipe";
      };

      home-manager.users.ghostty = {
        xdg.configFile = {
          "ghostty/config".text = ''
            bell-features = audio
            bell-audio-path = ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/bell.oga
            bell-audio-volume = 0
          '';
        };
      };
    };
    testScript = {nodes, ...}: let
      user = nodes.machine.users.users.ghostty;
      bus_path = "/run/user/${toString user.uid}/bus";
      bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}";
      gdbus = "${bus} gdbus";
      ghostty = "${bus} ghostty";
      su = command: "su - ${user.name} -c '${command}'";
      gseval = "call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval";
      wm_class = su "${gdbus} ${gseval} global.display.focus_window.wm_class";

      # Emits N BELs >100ms apart (which clears the bell rate-limit), then holds
      # so the window (and its audio pipeline) stays alive while we sample. Run
      # by typing its path into the open window; written as a script to avoid
      # shell-escaping the BEL byte through the test driver.
      ringBells = pkgs.writeShellScript "ring-bells" ''
        for _ in $(seq 100); do printf '\a'; sleep 0.12; done
        sleep 60
      '';
    in ''
      # Thread count of the ghostty GUI process: the ghostty process with the
      # most threads. The CLI also spawns 1-thread launcher/helper stubs (and
      # this very command matches the pgrep), but those are filtered by the max.
      def ghostty_threads():
          out = machine.succeed(
              "max=0; "
              "for p in $(pgrep -f ghostty); do "
              "  n=$(ls /proc/$p/task 2>/dev/null | wc -l); "
              "  [ \"$n\" -gt \"$max\" ] && max=$n; "
              "done; "
              "echo $max"
          ).strip()
          return int(out)

      def window_open():
          status, _ = machine.execute("${wm_class} | grep -q 'com.mitchellh.ghostty-debug'")
          return status == 0

      with subtest("boot and open a keep-alive ghostty window"):
          start_all()
          machine.wait_for_x()
          machine.wait_for_file("${bus_path}")
          machine.systemctl("enable app-com.mitchellh.ghostty-debug.service", user="${user.name}")

          # Under software GL the +new-window D-Bus activation can exceed its
          # client-side timeout even though the window still comes up, so we
          # tolerate a failed call and (re)nudge until the window appears.
          for _ in range(6):
              machine.execute("${su "${ghostty} +new-window"}")
              if window_open():
                  break
              machine.sleep(5)
          assert window_open(), "ghostty window never appeared"
          machine.sleep(2)

      with subtest("ring 100 bells and assert the thread count stays bounded"):
          baseline = ghostty_threads()

          # Ring the bells by running the script inside the focused window (type
          # its path + Enter). A separate `ghostty -e` process can't open the
          # display from the bare su environment, so we drive the open window.
          machine.send_chars("${ringBells}\n")

          # 100 bells * 0.12s + settle, within the script's trailing hold so the
          # window (and its audio pipeline) is still alive when we sample.
          machine.sleep(22)
          final = ghostty_threads()

          growth = final - baseline
          print(f"bell-leak: baseline={baseline} final={final} growth={growth}")

          # Pre-fix grows ~4 threads/bell (~+400 over 100 bells); the fix adds
          # only one pipeline's worth of threads. 40 sits well clear of both.
          assert growth <= 40, (
              f"thread count grew by {growth} over 100 bells "
              f"(baseline={baseline}, final={final}): audio-bell pipeline leak regressed"
          )
    '';
  };
}
