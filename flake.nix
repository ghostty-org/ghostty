{
  description = "👻";

  inputs = {
    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    #
    # We are currently on nixpkgs-unstable to get Zig 0.15 for our package.nix and
    # Gnome 49/Gtk 4.20.
    #
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    flake-utils.url = "github:numtide/flake-utils";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "flake-compat";
      };
    };

    zon2nix = {
      url = "github:jcollie/zon2nix?rev=c28e93f3ba133d4c1b1d65224e2eebede61fd071";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    zon2nix,
    home-manager,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;

    # Our supported systems are the same supported systems as the Zig binaries.
    platforms = lib.attrNames zig.packages;

    # It's not always possible to build Ghostty with Nix for each system,
    # one such example being macOS due to missing Swift 6 and xcodebuild
    # support in the Nix ecosystem. Therefore for things like package outputs
    # we need to limit the attributes we expose.
    buildablePlatforms = lib.filter (p: !(lib.systems.elaborate p).isDarwin) platforms;

    forAllPlatforms = f: lib.genAttrs platforms (s: f legacyPackages.${s});
    forBuildablePlatforms = f: lib.genAttrs buildablePlatforms (s: f legacyPackages.${s});

    mkPkgArgs = optimize: {
      inherit optimize;
      revision = self.shortRev or self.dirtyShortRev or "dirty";
    };
  in {
    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig.packages.${pkgs.stdenv.hostPlatform.system}."0.15.2";
        wraptest = pkgs.callPackage ./nix/pkgs/wraptest.nix {};
        zon2nix = zon2nix;

        python3 = pkgs.python3.override {
          self = pkgs.python3;
          packageOverrides = pyfinal: pyprev: {
            blessed = pyfinal.callPackage ./nix/pkgs/blessed.nix {};
            ucs-detect = pyfinal.callPackage ./nix/pkgs/ucs-detect.nix {};
            wcwidth = pyfinal.callPackage ./nix/pkgs/wcwidth.nix {};
          };
        };
      };
    });

    packages =
      forAllPlatforms (pkgs: {
        # Deps are needed for environmental setup on macOS
        deps = pkgs.callPackage ./build.zig.zon.nix {};
      })
      // forBuildablePlatforms (pkgs: rec {
        ghostty-debug = pkgs.callPackage ./nix/package.nix (mkPkgArgs "Debug");
        ghostty-releasesafe = pkgs.callPackage ./nix/package.nix (mkPkgArgs "ReleaseSafe");
        ghostty-releasefast = pkgs.callPackage ./nix/package.nix (mkPkgArgs "ReleaseFast");

        ghostty = ghostty-releasefast;
        default = ghostty;
      });

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);

    apps = forBuildablePlatforms (pkgs: let
      runVM = module: let
        vm = import ./nix/vm/create.nix {
          inherit (pkgs.stdenv.hostPlatform) system;
          inherit module nixpkgs;
          overlay = self.overlays.debug;
        };
        program = pkgs.writeShellScript "run-ghostty-vm" ''
          SHARED_DIR=$(pwd)
          export SHARED_DIR

          ${pkgs.lib.getExe vm.config.system.build.vm} "$@"
        '';
      in {
        type = "app";
        program = "${program}";
        meta.description = "start a vm from ${toString module}";
      };
    in {
      wayland-cinnamon = runVM ./nix/vm/wayland-cinnamon.nix;
      wayland-gnome = runVM ./nix/vm/wayland-gnome.nix;
      wayland-plasma6 = runVM ./nix/vm/wayland-plasma6.nix;
      x11-cinnamon = runVM ./nix/vm/x11-cinnamon.nix;
      x11-plasma6 = runVM ./nix/vm/x11-plasma6.nix;
      x11-xfce = runVM ./nix/vm/x11-xfce.nix;
    });

    checks = forAllPlatforms (pkgs:
      import ./nix/tests.nix {
        inherit home-manager nixpkgs self;
        inherit (pkgs.stdenv.hostPlatform) system;
      });

    overlays = {
      default = self.overlays.releasefast;
      releasefast = final: prev: {
        ghostty = final.callPackage ./nix/package.nix (mkPkgArgs "ReleaseFast");
      };
      debug = final: prev: {
        ghostty = final.callPackage ./nix/package.nix (mkPkgArgs "Debug");
      };
    };
  };

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
