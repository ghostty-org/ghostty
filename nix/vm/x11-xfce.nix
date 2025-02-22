{...}: {
  imports = [
    ./common-xfce.nix
  ];

  services.displayManager.defaultSession = "xfce";
}
