{
  dbus,
  fetchFromGitLab,
  gobject-introspection,
  lib,
  libadwaita,
  meson,
  ninja,
  python3,
  stdenv,
  testers,
  xvfb-run,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "blueprint-compiler";
  version = "0.16.0";

  src = fetchFromGitLab {
    domain = "gitlab.gnome.org";
    owner = "jwestman";
    repo = "blueprint-compiler";
    rev = "v${finalAttrs.version}";
    hash = "sha256-FnMQtqy+uejWn3tDeaj92h2x9TzyiK5KdlRm55ObgPg=";
  };

  nativeBuildInputs = [
    meson
    ninja
  ];

  postPatch = ''
    patchShebangs docs/collect-sections.py
  '';

  buildInputs = [
    libadwaita
    (python3.withPackages (
      ps:
        with ps; [
          pygobject3
        ]
    ))
  ];

  propagatedBuildInputs = [
    # For setup hook, so that the compiler can find typelib files
    gobject-introspection
  ];

  nativeCheckInputs = [
    dbus
    xvfb-run
  ];

  # requires xvfb-run
  doCheck = !stdenv.hostPlatform.isDarwin && false; # tests time out

  checkPhase = ''
    runHook preCheck

    xvfb-run dbus-run-session \
      --config-file=${dbus}/share/dbus-1/session.conf \
      meson test --no-rebuild --print-errorlogs

    runHook postCheck
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
  };

  meta = with lib; {
    description = "Markup language for GTK user interface files";
    mainProgram = "blueprint-compiler";
    homepage = "https://gitlab.gnome.org/jwestman/blueprint-compiler";
    license = licenses.lgpl3Plus;
    maintainers = with maintainers; [
      benediktbroich
      ranfdev
    ];
    platforms = platforms.unix;
  };
})
