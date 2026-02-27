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
buildPythonPackage {
  pname = "ucs-detect";
  version = "unstable-2026-02-23";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "ucs-detect";
    rev = "master";
    hash = "sha256-x7BD14n1/mP9bzjM6DPqc5R1Fk/HLLycl4o41KV+xAE=";
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
}
