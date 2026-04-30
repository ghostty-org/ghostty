{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  flit-core,
  six,
  wcwidth,
}:
buildPythonPackage (finalAttrs: {
  pname = "blessed";
  version = "1.31";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "blessed";
    tag = finalAttrs.version;
    hash = "sha256-Nn+aiDk0Qwk9xAvAqtzds/WlrLAozjPL1eSVNU75tJA=";
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
})
