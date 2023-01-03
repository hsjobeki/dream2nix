<p align="center">
  <picture>
    <source width="600" media="(prefers-color-scheme: dark)" srcset="https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/0312cc4f785de36212f4303d23298f07c13549dc/dream2nix-dark.png">
    <source width="600" media="(prefers-color-scheme: light)" srcset="https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/e2a12a60ae49aa5eb11b42775abdd1652dbe63c0/dream2nix-01.png">
    <img width="600" alt="dream2nix - A framework for automated nix packaging" src="https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/e2a12a60ae49aa5eb11b42775abdd1652dbe63c0/dream2nix-01.png">
  </picture>
  <br>
  Automate reproducible packaging for various language ecosystems
  <br>
  <a href="https://nix-community.github.io/dream2nix/">Documentation</a> |
  <a href="https://nix-community.github.io/dream2nix/contributing.html">Contributing</a> |
  <a href="https://nix-community.github.io/dream2nix/intro/override-system.html">Overriding Packages</a> |
  <a href="https://github.com/nix-community/dream2nix/tree/main/examples">Examples</a>
</p>

!!! Warning: dream2nix is unstable software. While simple UX is one of our main focus points, the APIs  are still under development. Do expect changes that will break your setup.

### Ecosystem stats:
<p>
<a href="https://nix-community.github.io/dream2nix-auto-test/#pkgs-nodejs" target="_blank" rel="noopener noreferrer">
<img src="https://raw.githubusercontent.com/nix-community/dream2nix-auto-test/gh-pages/pkgs-nodejs.svg"></a>
<br>
<a href="https://nix-community.github.io/dream2nix-auto-test/#pkgs-haskell" target="_blank" rel="noopener noreferrer">
<img src="https://raw.githubusercontent.com/nix-community/dream2nix-auto-test/gh-pages/pkgs-haskell.svg"></a>
<br>
<a href="https://nix-community.github.io/dream2nix-auto-test/#pkgs-rust" target="_blank" rel="noopener noreferrer">
<img src="https://raw.githubusercontent.com/nix-community/dream2nix-auto-test/gh-pages/pkgs-rust.svg"></a>
</p>

### Funding

This project was funded through the [NGI Assure](https://nlnet.nl/assure) Fund, a fund established by [NLnet](https://nlnet.nl/) with financial support from the European Commission's [Next Generation Internet](https://ngi.eu/) programme, under the aegis of DG Communications Networks, Content and Technology under grant agreement No 957073. **Applications are still open, you can [apply today](https://nlnet.nl/propose)**.

Besides that, the project also receives private funding and support from [<img src="https://platonic.systems/logo.svg" height="25" width="25" alt=""> Platonic.Systems](https://platonic.systems).

If your organization wants to support the project with extra funding in order to add support for more languages or new features, please contact one of the maintainers.

## Goals

dream2nix focuses on the following aspects:

- Modularity
- Customizability
- Maintainability
- Nixpkgs Compatibility, by not enforcing IFD (import from derivation)
- Code de-duplication across 2nix converters
- Code de-duplication in nixpkgs
- Risk-free opt-in aggregated fetching (larger [FODs](https://nixos.wiki/wiki/Glossary), less checksums)
- Common UI across 2nix converters
- Reduce effort to develop new 2nix solutions
- Exploration and adoption of new nix features
- Simplified updating of packages

The goal of this project is to create a standardized, generic, modular framework for automated packaging solutions, aiming for better flexibility, maintainability and usability.

The intention is to integrate many existing 2nix converters into this framework, thereby improving many of the previously named aspects and providing a unified UX for all 2nix solutions.

### Test the experimental version of dream2nix

(Currently only nodejs and rust packaging is supported)

1. Make sure you use a nix version >= 2.4 and have `experimental-features = "nix-command flakes"` set.
1. Navigate to to the project intended to be packaged and initialize a dream2nix flake:
    ```command
      cd ./my-project
      nix flake init -t github:nix-community/dream2nix#simple
    ```
1. List the packages that can be built
    ```command
      nix flake show
    ```


Minimal Example `flake.nix`:
```nix
{
  inputs.dream2nix.url = "github:nix-community/dream2nix";
  outputs = { self, dream2nix }:
    dream2nix.lib.makeFlakeOutputs {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;
      source = ./.;
      projects = ./projects.toml;
    };
}
```

Extensive Example `flake.nix`:
```nix
{
  inputs.dream2nix.url = "github:nix-community/dream2nix";
  outputs = { self, dream2nix }:
    dream2nix.lib.makeFlakeOutputs {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;

      source = ./.;

      # `projects` can alternatively be an attrset.
      # `projects` can be omitted if `autoProjects = true` is defined.
      projects = ./projects.toml;

      # Configure the behavior of dream2nix when translating projects.
      # A setting applies to all discovered projects if `filter` is unset,
      # or just to a subset or projects if `filter` is used.
      settings = [
        # prefer aggregated source fetching (large FODs)
        {
          aggregate = true;
        }
        # for all impure nodejs projects with just a `package.json`,
        # add arguments for the `package-json` translator
        {
          filter = project: project.translator == "package-json";
          subsystemInfo.npmArgs = "--legacy-peer-deps";
          subsystemInfo.nodejs = 18;
        }
      ];

      # configure package builds via overrides
      # (see docs for override system below)
      packageOverrides = {
        # name of the package
        package-name = {
          # name the override
          add-pre-build-steps = {
            # override attributes
            preBuild = "...";
            # update attributes
            buildInputs = old: old ++ [pkgs.hello];
          };
        };
      };

      # Inject missing dependencies
      inject = {
        # Make foo depend on bar and baz
        # from
        foo."6.4.1" = [
          # to
          ["bar" "13.2.0"]
          ["baz" "1.0.0"]
        ];
        # dependencies with @ and slash require quoting
        # the format is the one that is in the lockfile
        "@tiptap/extension-code"."2.0.0-beta.26" = [
           ["@tiptap/core" "2.0.0-beta.174"]
         ];
      };

      # add sources for `bar` and `baz`
      sourceOverrides = oldSources: {
        bar."13.2.0" = builtins.fetchTarball {url = ""; sha256 = "";};
        baz."1.0.0" = builtins.fetchTarball {url = ""; sha256 = "";};
      };
    };
}
```

An example for instancing dream2nix per pkgs and using it to create outputs can be found at [`examples_d2n-init-pkgs`](./examples/_d2n-init-pkgs/flake.nix).

### Documentation

Documentation for `main` branch is deployed to https://nix-community.github.io/dream2nix.

A CLI app is available if you want to read documentation in your terminal.
The app is available as `d2n-docs` if you enter the development shell, otherwise you can access it with `nix run .#docs`.
`d2n-docs` can be used to access all available documentation.
To access a specific document you can use `d2n-docs doc-name` where `doc-name` is the name of the document.
For example, to access Rust subsystem documentation, you can use `d2n-docs rust`.

You can also build documentation by running `nix build .#docs`.
Or by entering the development shell (`nix develop`) and running `mdbook build docs`.

### Watch the presentation

(The code examples of the presentation are outdated)
[![dream2nix - A generic framework for 2nix tools](https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/3c8b2c56f5fca3bf5c343ffc179136eef39d4d6a/dream2nix-youtube-talk.png)](https://www.youtube.com/watch?v=jqCfHMvCsfQ)

### Community

matrix: https://matrix.to/#/#dream2nix:nixos.org

