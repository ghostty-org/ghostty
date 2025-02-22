# Ghostty Development Process

This document describes the development process for Ghostty. It is intended for
anyone considering opening an **issue** or **pull request**. If in doubt,
please open a [discussion](https://github.com/ghostty-org/ghostty/discussions);
we can always convert that to an issue later.

> [!NOTE]
>
> I'm sorry for the wall of text. I'm not trying to be difficult and I do
> appreciate your contributions. Ghostty is a personal project for me that
> I maintain in my free time. If you're expecting me to dedicate my personal
> time to fixing bugs, maintaining features, and reviewing code, I do kindly
> ask you spend a few minutes reading this document. Thank you. ❤️

## Quick Guide

**I'd like to contribute!**

All issues are actionable. Pick one and start working on it. Thank you.
If you need help or guidance, comment on the issue. Issues that are extra
friendly to new contributors are tagged with "contributor friendly".

**I have a bug!**

1. Search the issue tracker and discussions for similar issues.
2. If you don't have steps to reproduce, open a discussion.
3. If you have steps to reproduce, open an issue.

**I have an idea for a feature!**

1. Open a discussion.

**I've implemented a feature!**

1. If there is an issue for the feature, open a pull request.
2. If there is no issue, open a discussion and link to your branch.
3. If you want to live dangerously, open a pull request and hope for the best.

**I have a question!**

1. Open a discussion or use Discord.

## General Patterns

### Issues are Actionable

The Ghostty [issue tracker](https://github.com/ghostty-org/ghostty/issues)
is for _actionable items_.

Unlike some other projects, Ghostty **does not use the issue tracker for
discussion or feature requests**. Instead, we use GitHub
[discussions](https://github.com/ghostty-org/ghostty/discussions) for that.
Once a discussion reaches a point where a well-understood, actionable
item is identified, it is moved to the issue tracker. **This pattern
makes it easier for maintainers or contributors to find issues to work on
since _every issue_ is ready to be worked on.**

If you are experiencing a bug and have clear steps to reproduce it, please
open an issue. If you are experiencing a bug but you are not sure how to
reproduce it or aren't sure if it's a bug, please open a discussion.
If you have an idea for a feature, please open a discussion.

### Pull Requests Implement an Issue

Pull requests should be associated with a previously accepted issue.
**If you open a pull request for something that wasn't previously discussed,**
it may be closed or remain stale for an indefinite period of time. I'm not
saying it will never be accepted, but the odds are stacked against you.

Issues tagged with "feature" represent accepted, well-scoped feature requests.
If you implement an issue tagged with feature as described in the issue, your
pull request will be accepted with a high degree of certainty.

> [!NOTE]
>
> **Pull requests are NOT a place to discuss feature design.** Please do
> not open a WIP pull request to discuss a feature. Instead, use a discussion
> and link to your branch.

# Developer Guide

> [!NOTE]
>
> **The remainder of this file is dedicated to developers actively
> working on Ghostty.** If you're a user reporting an issue, you can
> ignore the rest of this document.

## Input Stack Testing

The input stack is the part of the codebase that starts with a
key event and ends with text encoding being sent to the pty (it
does not include _rendering_ the text, which is part of the
font or rendering stack).

If you modify any part of the input stack, you must manually verify
all the following input cases work properly. We unfortunately do
not automate this in any way, but if we can do that one day that'd
save a LOT of grief and time.

Note: this list may not be exhaustive, I'm still working on it.

### Linux IME

IME (Input Method Editors) are a common source of bugs in the input stack,
especially on Linux since there are multiple different IME systems
interacting with different windowing systems and application frameworks
all written by different organizations.

The following matrix should be tested to ensure that all IME input works
properly:

1. Wayland, X11
2. ibus, fcitx, none
3. Dead key input (e.g. Spanish), CJK (e.g. Japanese), Emoji, Unicode Hex
4. ibus versions: 1.5.29, 1.5.30, 1.5.31 (each exhibit slightly different behaviors)

> [!NOTE]
>
> This is a **work in progress**. I'm still working on this list and it
> is not complete. As I find more test cases, I will add them here.

#### Dead Key Input

Set your keyboard layout to "Spanish" (or another layout that uses dead keys).

1. Launch Ghostty
2. Press `'`
3. Press `a`
4. Verify that `á` is displayed

Note that the dead key may or may not show a preedit state visually.
For ibus and fcitx it does but for the "none" case it does not. Importantly,
the text should be correct when it is sent to the pty.

We should also test canceling dead key input:

1. Launch Ghostty
2. Press `'`
3. Press escape
4. Press `a`
5. Verify that `a` is displayed (no diacritic)

#### CJK Input

Configure fcitx or ibus with a keyboard layout like Japanese or Mozc. The
exact layout doesn't matter.

1. Launch Ghostty
2. Press `Ctrl+Shift` to switch to "Hiragana"
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Press `Enter`
5. Verify that `こん` is displayed in the terminal.

We should also test switching input methods while preedit is active, which
should commit the text:

1. Launch Ghostty
2. Press `Ctrl+Shift` to switch to "Hiragana"
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Press `Ctrl+Shift` to switch to another layout (any)
5. Verify that `こん` is displayed in the terminal as committed text.

## Nix Virtual Machines

Several Nix virtual machine definitions are provided by the project for testing
and developing Ghostty against multiple different Linux desktop environments.

Running these requires a working Nix installation, either Nix on your
favorite Linux distribution, NixOS, or macOS with nix-darwin installed. Further
requirements for macOS are detailed below.

VMs should only be run on your local desktop and then powered off when not in
use, which will discard any changes to the VM.

The VM definitions provide minimal software "out of the box" but additional
software can be installed by using standard Nix mechanisms like `nix run nixpkgs#<package>`.

### Linux

1. Check out the Ghostty source and change to the directory.
2. Run `nix run .#<vmtype>`. `<vmtype>` can be any of the VMs defined in the
   `nix/vm` directory (without the `.nix` suffix) excluding any file prefixed
   with `common` or `create`.
3. The VM will build and then launch. Depending on the speed of your system, this
   can take a while, but eventually you should get a new VM window.
4. The Ghostty source directory should be mounted to `/tmp/shared` in the VM. Depending
   on what UID and GID of the user that you launched the VM as, `/tmp/shared` _may_ be
   writable by the VM user, so be careful!

### macOS

1. To run the VMs on macOS you will need to enable the Linux builder in your `nix-darwin`
   config. This _should_ be as simple as adding `nix.linux-builder.enable=true` to your
   configuration and then rebuilding. See [this](https://nixcademy.com/posts/macos-linux-builder/)
   blog post for more information about the Linux builder and how to tune the performance.
2. Once the Linux builder has been enabled, you should be able to follow the Linux instructions
   above to launch a VM.

### Custom VMs

To easily create a custom VM without modifying the Ghostty source, create a new
directory, then create a file called `flake.nix` with the following text in the
new directory.

```
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    ghostty.url = "github:ghostty-org/ghostty";
  };
  outputs = {
    nixpkgs,
    ghostty,
    ...
  }: {
   nixosConfigurations.custom-vm = ghostty.create-gnome-vm {
     nixpkgs = nixpkgs;
     system = "x86_64-linux";
     overlay = ghostty.overlays.releasefast;
     # module = ./configuration.nix # also works
     module = {pkgs, ...}: {
       environment.systemPackages = [
         pkgs.btop
       ];
     };
    };
  };
}
```

The custom VM can then be run with a command like this:

```
nix run .#nixosConfigurations.custom-vm.config.system.build.vm
```

A file named `ghostty.qcow2` will be created that is used to persist any changes
made in the VM. To "reset" the VM to default delete the file and it will be
recreated the next time you run the VM.

### Contributing new VM definitions

#### VM Acceptance Criteria

We welcome the contribution of new VM definitions, as long as they meet the following criteria:

1. The should be different enough from existing VM definitions that they represent a distinct
   user (and developer) experience.
2. There's a significant Ghostty user population that uses a similar environment.
3. The VMs can be built using only packages from the current stable NixOS release.

#### VM Definition Criteria

1. VMs should be as minimal as possible so that they build and launch quickly.
   Additional software can be added at runtime with a command like `nix run nixpkgs#<package name>`.
2. VMs should not expose any services to the network, or run any remote access
   software like SSH daemons, VNC or RDP.
3. VMs should auto-login using the "ghostty" user.
