{
  description = "👻";

  inputs = {
    nixpkgs-24-05.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs-24-05";
      };
    };

    zls = {
      url = "github:zigtools/zls/master";
      inputs = {
        nixpkgs.follows = "nixpkgs-24-05";
        zig-overlay.follows = "zig";
      };
    };
  };

  outputs = {
    self,
    nixpkgs-24-05,
    nixpkgs-unstable,
    zig,
    zls,
  }:
    builtins.foldl' nixpkgs-24-05.lib.attrsets.recursiveUpdate {} (
      builtins.map
      (
        system: let
          pkgs-24-05 = import nixpkgs-24-05 {
            inherit system;
          };
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
          };
        in {
          devShells.${system} = {
            default = self.devShells.${system}."ghostty-24-05";
            "ghostty-24-05" = pkgs-24-05.callPackage ./nix/devShell.nix {
              zig_0_13 = zig.packages.${system}."0.13.0";
              zls = zls.packages.${system}.zls;
              wraptest = pkgs-24-05.callPackage ./nix/wraptest.nix {};
            };
            "ghostty-unstable" = pkgs-unstable.callPackage ./nix/devShell.nix {
              zig_0_13 = zig.packages.${system}."0.13.0";
              zls = zls.packages.${system}.zls;
              wraptest = pkgs-24-05.callPackage ./nix/wraptest.nix {};
            };
          };

          packages.${system} = let
            mkArgs = optimize: {
              inherit (pkgs-unstable) zig_0_13 lib;
              inherit optimize;

              revision = self.shortRev or self.dirtyShortRev or "dirty";
            };
          in {
            default = self.packages.${system}.ghostty;
            ghostty = self.packages.${system}.ghostty-releasefast;
            ghostty-debug = self.packages.${system}.ghostty-24-05-debug;
            ghostty-releasesafe = self.packages.${system}.ghostty-24-05-releasesafe;
            ghostty-releasefast = self.packages.${system}.ghostty-24-05-releasefast;
            ghostty-24-05-debug = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-24-05-releasesafe = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-24-05-releasefast = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "ReleaseFast");
            ghostty-unstable-debug = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-unstable-releasesafe = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-unstable-releasefast = pkgs-24-05.callPackage ./nix/package.nix (mkArgs "ReleaseFast");
          };

          formatter.${system} = pkgs-24-05.alejandra;
        }
      )
      # Our supported systems are the same supported systems as the Zig binaries.
      (builtins.attrNames zig.packages)
    );

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
