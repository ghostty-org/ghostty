{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  hatchling,
  # Dependencies
  blessed,
  wcwidth,
  pyyaml,
  prettytable,
  requests,
}:
buildPythonPackage (finalAttrs: {
  pname = "ucs-detect";
  version = "2.0.2";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "ucs-detect";
    tag = finalAttrs.version;
    hash = "sha256-pCJNrJN+SO0pGveNJuISJbzOJYyxP9Tbljp8PwqbgYU=";
  };

  dependencies = [
    blessed
    wcwidth
    pyyaml
    prettytable
    requests
  ];

  nativeBuildInputs = [hatchling];

  doCheck = false;
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    description = "Measures number of Terminal column cells of wide-character codes";
    homepage = "https://github.com/jquast/ucs-detect";
    license = licenses.mit;
    maintainers = [];
  };
})
