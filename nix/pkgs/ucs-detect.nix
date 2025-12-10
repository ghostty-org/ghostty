{
  lib,
  buildPythonPackage,
  fetchPypi,
  pythonOlder,
  setuptools,
  # Dependencies
  blessed,
  wcwidth,
  pyyaml,
}:
buildPythonPackage rec {
  pname = "ucs-detect";
  version = "1.0.8";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchPypi {
    inherit version;
    pname = "ucs_detect";
    hash = "sha256-ihB+tZCd6ykdeXYxc6V1Q6xALQ+xdCW5yqSL7oppqJc=";
  };

  dependencies = [
    blessed
    wcwidth
    pyyaml
  ];

  nativeBuildInputs = [setuptools];

  doCheck = false;

  meta = with lib; {
    description = "Measures number of Terminal column cells of wide-character codes";
    homepage = "https://github.com/jquast/ucs-detect";
    license = licenses.mit;
    maintainers = [];
  };
}
