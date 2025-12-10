{
  lib,
  buildPythonPackage,
  fetchPypi,
  pythonOlder,
  flit-core,
  six,
  wcwidth,
}:
buildPythonPackage rec {
  pname = "blessed";
  version = "1.23.0";
  pyproject = true;

  disabled = pythonOlder "3.7";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-VlkaMpZvcE9hMfFACvQVHZ6PX0FEEzpcoDQBl2Pe53s=";
  };

  build-system = [flit-core];

  propagatedBuildInputs = [
    wcwidth
    six
  ];

  doCheck = false;

  meta = with lib; {
    homepage = "https://github.com/jquast/blessed";
    description = "Thin, practical wrapper around terminal capabilities in Python";
    maintainers = [];
    license = licenses.mit;
  };
}
