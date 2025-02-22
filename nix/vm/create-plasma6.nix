{
  system,
  nixpkgs,
  overlay,
  module,
  uid ? 1000,
  gid ? 1000,
}:
import ./create.nix {
  inherit system nixpkgs overlay module uid gid;
  common = ./common-plasma6.nix;
}
