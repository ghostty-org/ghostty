{
  description = "👻";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs-23-05.url = "github:nixos/nixpkgs/release-23.05";
    nixpkgs-23-11.url = "github:nixos/nixpkgs/release-23.11";

    # This is a nixpkgs mirror (based off of master) that contains
    # patches for Zig 0.12 (master/nightly).
    #
    # This gives an up-to-date Zig that contains the nixpkgs patches,
    # specifically the ones relating to NativeTargetInfo
    # (https://github.com/ziglang/zig/issues/15898) in addition to the base
    # hooks. This is used in the package (i.e. packages.ghostty, not the
    # devShell) to build a Zig that can be included in a NixOS configuration.
    nixpkgs-zig-0-12.url = "github:vancluever/nixpkgs/vancluever-zig-0-12";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs-23-11";
    };

    zls = {
      url = "github:zigtools/zls/master";
      inputs.nixpkgs.follows = "nixpkgs-23-11";
      inputs.zig-overlay.follows = "zig";
    };
  };

  outputs = {
    self,
    nixpkgs-23-05,
    nixpkgs-23-11,
    nixpkgs-unstable,
    nixpkgs-zig-0-12,
    zig,
    zls,
    ...
  }:
    builtins.foldl' nixpkgs-23-11.lib.recursiveUpdate {} (builtins.map (system: let
      pkgs-23-05 = nixpkgs-23-05.legacyPackages.${system};
      pkgs-23-11 = nixpkgs-23-11.legacyPackages.${system};
      pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
      pkgs-zig-0-12 = nixpkgs-zig-0-12.legacyPackages.${system};
    in {
      devShell.${system} = pkgs-23-11.callPackage ./nix/devShell.nix {
        inherit (pkgs-unstable) tracy;
        inherit (zls.packages.${system}) zls;

        zig = zig.packages.${system}.master-2024-01-06;
        wraptest = pkgs-23-11.callPackage ./nix/wraptest.nix {};
      };

      packages.${system} = rec {
        ghostty-23-05 = pkgs-23-05.callPackage ./nix/package.nix {
          inherit (pkgs-zig-0-12) zig_0_12;
          revision = self.shortRev or self.dirtyShortRev or "dirty";
        };
        ghostty-23-11 = pkgs-23-11.callPackage ./nix/package.nix {
          inherit (pkgs-zig-0-12) zig_0_12;
          revision = self.shortRev or self.dirtyShortRev or "dirty";
        };
        ghostty-unstable = pkgs-unstable.callPackage ./nix/package.nix {
          inherit (pkgs-zig-0-12) zig_0_12;
          revision = self.shortRev or self.dirtyShortRev or "dirty";
        };
        ghostty = ghostty-23-11;
        default = ghostty;
      };

      formatter.${system} = pkgs-23-11.alejandra;

      # Our supported systems are the same supported systems as the Zig binaries.
    }) (builtins.attrNames zig.packages));

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
