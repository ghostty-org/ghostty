{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  flit-core,
  six,
  wcwidth,
}:
buildPythonPackage {
  pname = "blessed";
  version = "unstable-2026-02-23";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "blessed";
    rev = "master";
    hash = "sha256-ROd/O9pfqnF5DHXqoz+tkl1jQJSZad3Ta1h+oC3+gvY=";
  };

  build-system = [flit-core];

  propagatedBuildInputs = [
    wcwidth
    six
  ];

  doCheck = false;
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    homepage = "https://github.com/jquast/blessed";
    description = "Thin, practical wrapper around terminal capabilities in Python";
    maintainers = [];
    license = licenses.mit;
  };
}
