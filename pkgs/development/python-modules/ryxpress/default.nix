{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pytestCheckHook,
  setuptools,
}:

buildPythonPackage rec {
  pname = "ryxpress";
  version = "0.0.9";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "b-rodrigues";
    repo = "ryxpress";
    tag = "v${version}";
    hash = "sha256-nK5S3a1YGreq5jjzYBd/QS7WhEDQpUUEoyEMiHGoWTQ=";
  };

  build-system = [ setuptools ];

  doCheck = false;

  pythonImportsCheck = [ "ryxpress" ];

  meta = with lib; {
    description = "Reproducible Analytical Pipelines with Nix";
    homepage = "https://github.com/b-rodrigues/ryxpress";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [ b-rodrigues ];
  };
}
