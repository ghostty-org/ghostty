{...}: {
  imports = [
    ./common.nix
  ];

  services.xserver = {
    displayManager = {
      lightdm = {
        enable = true;
      };
    };
    desktopManager = {
      xfce = {
        enable = true;
      };
    };
  };
}
