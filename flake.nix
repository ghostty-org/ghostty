{
  description = "ghostty";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
    zls-master.url = "github:zigtools/zls/master";

    # This is a nixpkgs mirror (based off of nixos-unstable) that contains
    # patches for LLVM 17 and Zig 0.12 (master/nightly).
    #
    # This gives an up-to-date Zig that contains the nixpkgs patches,
    # specifically the ones relating to NativeTargetInfo
    # (https://github.com/ziglang/zig/issues/15898) in addition to the base
    # hooks. This is used in the package (i.e. packages.ghostty, not the
    # devShell) to build a Zig that can be included in a NixOS configuration.
    nixpkgs-zig-0-12.url = "github:vancluever/nixpkgs/vancluever-zig-0-12";

    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs.url = "github:nixos/nixpkgs/release-23.05";

    # Used for shell.nix
    flake-compat = { url = github:edolstra/flake-compat; flake = false; };
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    let
      overlays = [
        # Our repo overlay
        (import ./nix/overlay.nix)

        # Other overlays
        (final: prev: {
          zigpkgs = inputs.zig.packages.${prev.system};

          zig_0_12 = inputs.nixpkgs-zig-0-12.legacyPackages.${prev.system}.zig_0_12;

          # Latest version of Tracy
          tracy = inputs.nixpkgs-unstable.legacyPackages.${prev.system}.tracy;

          # Latest version of ZLS
          zls = inputs.zls-master.packages.${prev.system}.zls;
        })
      ];

      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames inputs.zig.packages;
    in
    flake-utils.lib.eachSystem systems (system:
      let pkgs = import nixpkgs { inherit overlays system; };
      in rec {
        devShell = pkgs.devShell;

        # NOTE: using packages.ghostty right out of the flake currently
        # requires a build of LLVM 17 and Zig master from source. This will
        # take quite a bit of time. Until LLVM 17 and an upcoming Zig 0.12 are
        # up in nixpkgs, most folks will want to continue to use the devShell
        # and the instructions found at:
        #
        #   https://github.com/mitchellh/ghostty/tree/main#developing-ghostty
        #
        packages.ghostty = pkgs.ghostty;
        defaultPackage = packages.ghostty;
      }
    );
}
