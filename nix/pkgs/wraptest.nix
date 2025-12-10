{
  stdenv,
  fetchFromGitHub,
  autoPatchelfHook,
}:
stdenv.mkDerivation rec {
  version = "0.1.0-e7a96089";
  pname = "wraptest";

  src = fetchFromGitHub {
    owner = "mattiase";
    repo = pname;
    rev = "e7a960892873035d2ef56b9770c32b43635821fb";
    sha256 = "sha256-+v6xpPCmvKfsDkPmBSv6+6yAg2Kzame5Zwx2WKjQreI=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
  ];

  buildPhase = ''
    runHook preBuild

    cc -O3 -o wraptest wraptest.c

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp wraptest $out/bin/

    runHook postInstall
  '';

  meta = {
    description = "Test of DEC VT terminal line-wrapping semantics";
    homepage = "https://github.com/mattiase/wraptest";
    platforms = ["aarch64-linux" "i686-linux" "x86_64-linux"];
  };
}
