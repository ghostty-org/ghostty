{
  description = "ghostty";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-23.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";

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

          # Latest version of Tracy
          tracy = inputs.nixpkgs-unstable.legacyPackages.${prev.system}.tracy;
        })
      ];

      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames inputs.zig.packages;
    in flake-utils.lib.eachSystem systems (system:
      let pkgs = import nixpkgs { inherit overlays system; };
      in rec {
        devShell = pkgs.devShell;
        packages.ghostty = pkgs.ghostty;
        defaultPackage = packages.ghostty;
      }
    );
}
