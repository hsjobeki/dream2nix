{
  dlib,
  lib,
  ...
}: let
  l = lib // builtins;
in {
  type = "pure";

  /*
  Automatically generate unit tests for this translator using project sources
  from the specified list.

  !!! Your first action should be adding a project here. This will simplify
  your work because you will be able to use `nix run .#tests-unit` to
  test your implementation for correctness.
  */
  generateUnitTestsForProjects = [
    (builtins.fetchTarball {
      url = "https://github.com/hsjobeki/deno-test/tarball/main";
      sha256 = "0h4cfl1d43sjkh2zghh6yhh1ba820zmhagm44bnjyrfxahssc57g";
    })
  ];

  discoverProject = tree:
    l.any
    (filename: l.hasSuffix "lock.json" filename)
    (l.attrNames tree.files);

  # translate from a given source and a project specification to a dream-lock.
  translate = {
    project,
    source,
    tree,
    ...
  } @ args: let
    # get the root source and project source
    rootSource = tree.fullPath;
    projectSource = "${tree.fullPath}/${project.relPath}";
    projectTree = tree.getNodeFromPath project.relPath;

    # parse the json / toml etc.
    lockJson = (projectTree.getNodeFromPath "lock.json").jsonContent;
  in {
    _generic = {
      defaultPackage = "deno-default-package";
      # where src tree is located (optional)
      # location
      packages = {
        "deno-default-package" = "unknown";
      };
      subsystem = "deno";
      # sourcesAggregatedHash =
    };
    _subsystem = {
      # add more stuff
      # denoAttr = ""
    };
    # https://cdn.skypack.dev/-/big.js@v5.2.2-sUR8fKsGHRxsJyqyvOSP/dist=es2019,mode=imports/optimized/bigjs.js = "sha256:khjdga"
    # -/big.js@v5.2.2-sUR8fKsGHRxsJyqyvOSP/dist=es2019,mode=imports/optimized/bigjs.js -> sha256 -> sha256:abc
    #
    # cdn.skypack.dev
    #   sha256:abckhaskdjhasd.ts
    #   sha256:abckhaskdjhasd.metadata.json

    sources =
      builtins.mapAttrs (url: hash: {
        ${hash} = {
          inherit url hash;
          # version="unknown";
          # type=if l.hasPrefix "http" url then "http" else ""
          type = "http";
        };
      })
      lockJson;
  };
}
