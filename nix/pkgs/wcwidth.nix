{
  lib,
  buildPythonPackage,
  fetchPypi,
  hatchling,
}:
buildPythonPackage rec {
  pname = "wcwidth";
  version = "0.6.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-zcTkJi1u+aGlfgGDhMvrEgjYq7xkF2An4sJFXIExMVk=";
  };

  build-system = [hatchling];

  doCheck = false;

  meta = with lib; {
    description = "Measures the displayed width of unicode strings in a terminal";
    homepage = "https://github.com/jquast/wcwidth";
    license = licenses.mit;
    maintainers = [];
  };
}
