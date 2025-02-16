{...}: {
  imports = [
    ./common-plasma6.nix
  ];
  services.displayManager.defaultSession = "plasma";
}
