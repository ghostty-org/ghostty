{
  description = "👻";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs-stable.url = "github:nixos/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "";
      };
    };

    zig2nix = {
      url = "github:jcollie/zig2nix?ref=c311d8e77a6ee0d995f40a6e10a89a3a4ab04f9a";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = {
    self,
    nixpkgs-unstable,
    nixpkgs-stable,
    zig,
    zig2nix,
    ...
  }:
    builtins.foldl' nixpkgs-stable.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs-stable = nixpkgs-stable.legacyPackages.${system};
          pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
        in {
          devShell.${system} = pkgs-stable.callPackage ./nix/devShell.nix {
            zig = zig.packages.${system}."0.13.0";
            wraptest = pkgs-stable.callPackage ./nix/wraptest.nix {};
            zig2nix = zig2nix;
          };

          packages.${system} = let
            mkArgs = optimize: {
              inherit optimize;

              revision = self.shortRev or self.dirtyShortRev or "dirty";
            };
          in rec {
            deps = pkgs-stable.callPackage ./build.zig.zon.nix {};
            ghostty-debug = pkgs-stable.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-releasesafe = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-releasefast = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseFast");

            ghostty = ghostty-releasefast;
            default = ghostty;
          };

          formatter.${system} = pkgs-stable.alejandra;

          apps.${system} = let
            runVM = (
              module: let
                vm = import ./nix/vm/create.nix {
                  inherit system module;
                  nixpkgs = nixpkgs-stable;
                  overlay = self.overlays.debug;
                };
                program = pkgs-stable.writeShellScript "run-ghostty-vm" ''
                  SHARED_DIR=$(pwd)
                  export SHARED_DIR

                  ${pkgs-stable.lib.getExe vm.config.system.build.vm} "$@"
                '';
              in {
                type = "app";
                program = "${program}";
              }
            );
          in {
            wayland-cinnamon = runVM ./nix/vm/wayland-cinnamon.nix;
            wayland-gnome = runVM ./nix/vm/wayland-gnome.nix;
            wayland-plasma6 = runVM ./nix/vm/wayland-plasma6.nix;
            x11-cinnamon = runVM ./nix/vm/x11-cinnamon.nix;
            x11-gnome = runVM ./nix/vm/x11-gnome.nix;
            x11-plasma6 = runVM ./nix/vm/x11-plasma6.nix;
            x11-xfce = runVM ./nix/vm/x11-xfce.nix;
          };
        }
        # Our supported systems are the same supported systems as the Zig binaries.
      ) (builtins.attrNames zig.packages)
    )
    // {
      overlays = {
        default = self.overlays.releasefast;
        releasefast = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-releasefast;
        };
        debug = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-debug;
        };
      };
      create-vm = import ./nix/vm/create.nix;
      create-cinnamon-vm = import ./nix/vm/create-cinnamon.nix;
      create-gnome-vm = import ./nix/vm/create-gnome.nix;
      create-plasma6-vm = import ./nix/vm/create-plasma6.nix;
      create-xfce-vm = import ./nix/vm/create-xfce.nix;
    };

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
