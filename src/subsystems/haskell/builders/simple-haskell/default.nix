{
  pkgs,
  utils,
  externals,
  inputs,
  lib,
  ...
}: let
  l = lib // builtins;
in {
  type = "pure";

  build = {
    ### FUNCTIONS
    # AttrSet -> Bool) -> AttrSet -> [x]
    getCyclicDependencies, # name: version: -> [ {name=; version=; } ]
    getDependencies, # name: version: -> [ {name=; version=; } ]
    getSource, # name: version: -> store-path
    # to get information about the original source spec
    getSourceSpec, # name: version: -> {type="git"; url=""; hash="";}
    ### ATTRIBUTES
    subsystemAttrs, # attrset
    defaultPackageName, # string
    defaultPackageVersion, # string
    # all exported (top-level) package names and versions
    # attrset of pname -> version,
    packages,
    # all existing package names and versions
    # attrset of pname -> versions,
    # where versions is a list of version strings
    packageVersions,
    # function which applies overrides to a package
    # It must be applied by the builder to each individual derivation
    # Example:
    #   produceDerivation name (mkDerivation {...})
    produceDerivation,
    ...
  } @ args: let
    compiler =
      pkgs
      .haskell
      .packages
      ."${subsystemAttrs.compiler.name}${
        l.stringAsChars (c:
          if c == "."
          then ""
          else c)
        subsystemAttrs.compiler.version
      }"
      or (throw "Could not find ${subsystemAttrs.compiler.name} version ${subsystemAttrs.compiler.version} in pkgs");

    cabalFiles =
      l.mapAttrs
      (key: hash: let
        split = l.splitString "#" key;
      in
        fetchCabalFile {
          inherit hash;
          pname = l.head split;
          version = l.last split;
        })
      subsystemAttrs.cabalHashes or {};

    # packages to export
    packages =
      {default = packages.${defaultPackageName};}
      // (
        lib.mapAttrs
        (name: version: {"${version}" = allPackages.${name}.${version};})
        args.packages
      );

    # manage packages in attrset to prevent duplicated evaluation
    allPackages =
      lib.mapAttrs
      (name: versions:
        lib.genAttrs
        versions
        (version: makeOnePackage name version))
      packageVersions;

    # fetches a cabal file for a given candidate and cabal-file-hash
    fetchCabalFile = {
      hash,
      pname,
      version,
    }:
      pkgs.runCommand
      "${pname}.cabal"
      {
        buildInputs = [
          pkgs.curl
          pkgs.cacert
        ];
        outputHash = hash;
        outputHashAlgo = "sha256";
        outputHashMode = "flat";
      }
      ''
        revision=0
        while true; do
          # will fail if revision does not exist
          curl -f https://hackage.haskell.org/package/${pname}-${version}/revision/$revision.cabal > cabal
          hash=$(sha256sum cabal | cut -d " " -f 1)
          echo "revision $revision: hash $hash; wanted hash: ${hash}"
          if [ "$hash" == "${hash}" ]; then
            mv cabal $out
            break
          fi
          revision=$(($revision + 1))
        done
      '';

    # Generates a derivation for a specific package name + version
    makeOnePackage = name: version: let
      pkg = compiler.mkDerivation (rec {
          pname = l.strings.sanitizeDerivationName name;
          inherit version;
          license = null;

          src = getSource name version;

          isLibrary = true;
          isExecutable = true;
          doCheck = false;
          doBenchmark = false;

          # FIXME: this skips over the default package if its name isn't set properly
          configureFlags =
            (subsystemAttrs.cabalFlags."${name}"."${version}" or []) ++
            (map
              (dep: "--constraint=${dep.name}==${dep.version}")
              (getDependencies name version));

          libraryToolDepends = libraryHaskellDepends;
          executableHaskellDepends = libraryHaskellDepends;
          testHaskellDepends = libraryHaskellDepends;
          testToolDepends = libraryHaskellDepends;

          libraryHaskellDepends =
            map
            (dep: allPackages."${dep.name}"."${dep.version}")
            (getDependencies name version);
        }
        /*
        For all transitive dependencies, overwrite cabal file with the one
        specified in the dream-lock
        */
        // (
          l.optionalAttrs (name != defaultPackageName)
          {
            preConfigure =
              if cabalFiles ? "${name}#${version}"
              then ''
                cp ${cabalFiles."${name}#${version}"} ./${name}.cabal
              ''
              else ''
                cp ${inputs.all-cabal-json}/${name}/${version}/${name}.cabal ./
              '';
          }
        )
        # enable tests only for the top-level package
        // (l.optionalAttrs (name == defaultPackageName) {
          doCheck = true;
        }));
    in
      # apply packageOverrides to current derivation
      produceDerivation name pkg;
  in {
    inherit packages;
  };
}
