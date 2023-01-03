{python310Packages}: {
  pyTests = python310Packages.buildPythonApplication {
    pname = "builder";
    version = "0.1.0";
    src = ../../tests/bin_tests;
    format = "pyproject";
    nativeBuildInputs = with python310Packages; [poetry mypy flake8 black];
    doCheck = false;
  };
  # ...
  # currently only pyTests exported
  # extend thus set for future tests
}
