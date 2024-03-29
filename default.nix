{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs
, yarn ? pkgs.yarn
, allowAliases ? pkgs.config.allowAliases or true
}:

let
  inherit (pkgs) stdenv lib fetchurl linkFarm callPackage git makeWrapper runCommandLocal;

  compose = f: g: x: f (g x);
  id = x: x;
  composeAll = builtins.foldl' compose id;

  # https://docs.npmjs.com/files/package.json#license
  # TODO: support expression syntax (OR, AND, etc)
  getLicenseFromSpdxId = licstr:
    if licstr == "UNLICENSED" then
      lib.licenses.unfree
    else
      lib.getLicenseFromSpdxId licstr;
in rec {
  # Export yarn again to make it easier to find out which yarn was used.
  inherit yarn;

  # Re-export pkgs
  inherit pkgs;

  unlessNull = item: alt:
    if item == null then alt else item;

  reformatPackageName = pname:
    let
      # regex adapted from `validate-npm-package-name`
      # will produce 3 parts e.g.
      # "@someorg/somepackage" -> [ "@someorg/" "someorg" "somepackage" ]
      # "somepackage" -> [ null null "somepackage" ]
      parts = builtins.tail (builtins.match "^(@([^/]+)/)?([^/]+)$" pname);
      # if there is no organisation we need to filter out null values.
      non-null = builtins.filter (x: x != null) parts;
    in builtins.concatStringsSep "-" non-null;

  inherit getLicenseFromSpdxId;

  mkYarnLock = path: builtins.path { name = "yarn-lock"; inherit path; };

  mkPackageJSON = path: builtins.path { name = "package-json"; inherit path; };

  # Generates the yarn.nix from the yarn.lock file
  mkYarnNix = { yarnLock, flags ? [] }:
    pkgs.runCommand "yarn.nix" {}
    "${yarn2nix}/bin/yarn2nix --lockfile ${mkYarnLock yarnLock} --no-patch --builtin-fetchgit ${lib.escapeShellArgs flags} > $out";

  # Loads the generated offline cache. This will be used by yarn as
  # the package source.
  importOfflineCache = yarnNix:
    let
      pkg = callPackage yarnNix { };
    in
      pkg.offline_cache;

  defaultYarnFlags = [
    "--offline"
    "--frozen-lockfile"
    "--ignore-engines"
    "--ignore-scripts"
    "--non-interactive"
    "--no-progress"
  ];

  mkYarnModules' = {
    name ? "${pname}-${version}", # safe name and version, e.g. testcompany-one-modules-1.0.0
    pname, # original name, e.g @testcompany/one
    version,
    packageJSON,
    yarnLock,
    yarnNix ? mkYarnNix { inherit yarnLock; },
    offlineCache ? importOfflineCache yarnNix,
    yarnFlags ? defaultYarnFlags,
    pkgConfig ? {},
    preBuild ? "",
    postBuild ? "",
    workspaceDependencies ? [], # List of yarn packages
    packageResolutions ? {},
  }:
    let
      yarnLock' = mkYarnLock yarnLock;
      packageJSON' = mkPackageJSON packageJSON;

      workspaceJSON = pkgs.writeText
        "${name}-workspace-package.json"
        (builtins.toJSON { private = true; workspaces = ["deps/**"]; resolutions = packageResolutions; }); # scoped packages need second splat

      workspaceDependencyLinks = lib.concatMapStringsSep "\n"
        (dep: ''
          mkdir -p "deps/${dep.pname}"
          tar -xf "${dep}/tarballs/${dep.name}.tgz" --directory "deps/${dep.pname}" --strip-components=1
        '')
        workspaceDependencies;

      createPatchFunction = ''
        createPatch() {
          echo "(cd \$1"
          echo "patch -sfp1 <<'EOF'"
          git --no-pager diff --no-color --no-index --no-prefix --diff-filter=d "$1" "$2" || true
          echo "EOF"
          echo "xargs rm -fr <<'EOF'"
          git --no-pager diff --no-color --no-index --no-prefix --irreversible-delete --diff-filter=D "$1" "$2" \
            | awk '{if (/^deleted file/) {sub("'$1'/","",x);print x};x=$3}' || true
          echo "EOF"
          echo "find . -type d -empty -delete)"
        }
      '';
    in stdenv.mkDerivation {
      inherit preBuild postBuild name;

      phases = [ "configurePhase" "buildPhase" ];
      nativeBuildInputs = [ yarn nodejs git ];

      configurePhase = lib.optionalString (offlineCache ? outputHash) ''
        if ! cmp -s ${yarnLock'} ${offlineCache}/yarn.lock; then
          echo "yarn.lock changed, you need to update the fetchYarnDeps hash"
          exit 1
        fi
      '' + ''
        # Yarn writes cache directories etc to $HOME.
        export HOME=$PWD/yarn_home
      '';

      buildPhase = ''
        runHook preBuild

        mkdir -p "deps/${pname}"
        cp ${packageJSON'} "deps/${pname}/package.json"
        ln -sT ../../../node_modules "deps/${pname}/node_modules"
        cp ${workspaceJSON} ./package.json
        cp ${yarnLock'} ./yarn.lock
        chmod +w ./yarn.lock

        yarn config --offline set yarn-offline-mirror ${offlineCache}

        # Do not look up in the registry, but in the offline cache.
        ${fixup_yarn_lock}/bin/fixup_yarn_lock yarn.lock

        ${workspaceDependencyLinks}

        yarn install ${lib.escapeShellArgs yarnFlags} --production=true
        mv node_modules node_modules_prod

        yarn install ${lib.escapeShellArgs yarnFlags}

        ${createPatchFunction}

        mkdir $out
        createPatch node_modules node_modules_prod | gzip > $out/prod.patch.gz
        mv node_modules $out/
        mv deps $out/
        patchShebangs $out

        runHook postBuild
      '';
    };

  fixYarnModule = {
    modules,
    pname,
    postInstall ? null,
    buildInputs ? [],
    nativeBuildInputs ? [],
    sourceFilter ? _path: _type: true,
    dependencyFilter ? _path: _name: _type: true
  }:
    let
      inherit (pkgs.lib) elem elemAt splitString reverseList foldl head tail;
      root = modules + "/node_modules";
      rootLen = (builtins.stringLength (toString root)) + 1;
      package = name:
        let p = "${root}/${name}/package.json"; in
        if builtins.pathExists p
        then builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile p))
        else {};

      packageDeps = type: name:
        builtins.attrNames ((package name).${type} or {});
      filteredDeps = type: path: name:
        builtins.filter
          (n: dependencyFilter "${path}/${name}/${n}" n type)
          (packageDeps type name);
      allDeps = name: (packageDeps "dependencies" name) ++ (packageDeps "devDependencies" name);
      allFilteredDeps = path: name: (filteredDeps "dependencies" path name) ++ (filteredDeps "devDependencies" path name);
      getDeps = path: builtins.foldl' (acc: dname:
        if builtins.elem dname acc
        then acc
        else getDeps "${path}/${dname}" (acc ++ [dname]) (allFilteredDeps path dname)
      );

      dirsToInclude = [pname] ++ getDeps "/${pname}" [] (allFilteredDeps "" pname);

      splitRegexPath = p:
        let ds = reverseList (splitString "/" p); in
        foldl (acc: d: "${d}(/${acc})?") (head ds) (tail ds);
      dirsToIncludeRegex = "(${lib.concatMapStringsSep "|" splitRegexPath dirsToInclude})/.*";
      match = path:
        ! builtins.isNull (builtins.match dirsToIncludeRegex path);

      pathFilter = path: type:
        let subpath = builtins.substring rootLen 10000000 path; in
        (
          # Files not in root directory (i.e. node_modules)
          (type == "regular"
            && ! isNull (builtins.match ".*/.*" subpath))
          # Directories under node_modules matching dependencies
          || match "${subpath}/")
        && (sourceFilter subpath type);

    in stdenv.mkDerivation {
      inherit pname buildInputs postInstall;
      name = pname + "-postinstall";
      src = builtins.path rec {
        name = "node_modules";
        path = root;
        filter = pathFilter;
      };
      nativeBuildInputs = [ nodejs git ] ++ nativeBuildInputs;
      phases = [ "unpackPhase" "installPhase" "fixupPhase" ];

      installPhase = ''
        cd $pname
        runHook postInstall

        mkdir -p $out/node_modules/$pname
        mv * $out/node_modules/$pname/
      '';
    };

  mkYarnModules = {
    name ? "${pname}-${version}", # safe name and version, e.g. testcompany-one-modules-1.0.0
    pname, # original name, e.g @testcompany/one
    version,
    packageJSON,
    yarnLock,
    yarnNix ? mkYarnNix { inherit yarnLock; },
    offlineCache ? importOfflineCache yarnNix,
    yarnFlags ? defaultYarnFlags,
    pkgConfig ? {},
    preBuild ? "",
    postBuild ? "",
    workspaceDependencies ? [], # List of yarn packages
    packageResolutions ? {},
  }@args:
    let
      modules = mkYarnModules' args;

      postInstallModules = (builtins.concatMap (key:
        let
          packageJSON = "${modules}/node_modules/${key}/package.json";
        in
        lib.optional (pkgConfig.${key} ? postInstall && builtins.pathExists packageJSON)
          (fixYarnModule {
            inherit modules;
            pname = key;
            postInstall = pkgConfig.${key}.postInstall;
            buildInputs = pkgConfig.${key}.buildInputs or [];
            nativeBuildInputs = pkgConfig.${key}.nativeBuildInputs or [];
            sourceFilter = pkgConfig.${key}.sourceFilter or (_: _: true);
            dependencyFilter = pkgConfig.${key}.dependencyFilter or (_: _: _: true);
          })
      ) (builtins.attrNames pkgConfig));
    in stdenv.mkDerivation {
      name = modules.name + "-postinstall";
      buildCommand = ''
        mkdir -p $out

        cp -r ${modules}/* $out/
        chmod -R +w $out
        ${lib.concatMapStringsSep "\n" (m: "cp -rf ${m}/node_modules/* $out/node_modules/") postInstallModules}
      '';
    };

  # This can be used as a shellHook in mkYarnPackage. It brings the built node_modules into
  # the shell-hook environment.
  linkNodeModulesHook = ''
    if [[ -d node_modules || -L node_modules ]]; then
      echo "./node_modules is present. Replacing."
      rm -rf node_modules
    fi

    ln -s "$node_modules" node_modules
  '';

  mkYarnWorkspace = {
    src,
    packageJSON ? src + "/package.json",
    yarnLock ? src + "/yarn.lock",
    packageOverrides ? {},
    ...
  }@attrs:
  let
    package = lib.importJSON (mkPackageJSON packageJSON);

    packageGlobs = if lib.isList package.workspaces then package.workspaces else package.workspaces.packages;

    packageResolutions = package.resolutions or {};

    globElemToRegex = lib.replaceStrings ["*"] [".*"];

    # PathGlob -> [PathGlobElem]
    splitGlob = lib.splitString "/";

    # Path -> [PathGlobElem] -> [Path]
    # Note: Only directories are included, everything else is filtered out
    expandGlobList = base: globElems:
      let
        elemRegex = globElemToRegex (lib.head globElems);
        rest = lib.tail globElems;
        children = lib.attrNames (lib.filterAttrs (name: type: type == "directory") (builtins.readDir base));
        matchingChildren = lib.filter (child: builtins.match elemRegex child != null) children;
      in if globElems == []
        then [ base ]
        else lib.concatMap (child: expandGlobList (base+("/"+child)) rest) matchingChildren;

    # Path -> PathGlob -> [Path]
    expandGlob = base: glob: expandGlobList base (splitGlob glob);

    packagePaths = lib.concatMap (expandGlob src) packageGlobs;

    packagePaths' = map (p: builtins.path { path = p; }) packagePaths;

    packages = lib.listToAttrs (map (src:
      let
        packageJSON = mkPackageJSON (src + "/package.json");

        package = lib.importJSON packageJSON;

        allDependencies = lib.foldl (a: b: a // b) {} (map (field: lib.attrByPath [field] {} package) ["dependencies" "devDependencies"]);

        # { [name: String] : { pname : String, packageJSON : String, ... } } -> { [pname: String] : version } -> [{ pname : String, packageJSON : String, ... }]
        getWorkspaceDependencies = packages: allDependencies:
          let
            packageList = lib.attrValues packages;
          in
            composeAll [
              (lib.filter (x: x != null))
              (lib.mapAttrsToList (pname: _version: lib.findFirst (package: package.pname == pname) null packageList))
            ] allDependencies;

        workspaceDependencies = getWorkspaceDependencies packages allDependencies;

        name = reformatPackageName package.name;
      in {
        inherit name;
        value = mkYarnPackage (
          builtins.removeAttrs attrs ["packageOverrides"]
          // { inherit src packageJSON packageResolutions workspaceDependencies;
            yarnLock = mkYarnLock yarnLock;
          } // lib.attrByPath [name] {} packageOverrides
        );
      })
      packagePaths'
    );
  in packages;

  mkYarnPackage = {
    name ? null,
    src,
    packageJSON ? src + "/package.json",
    yarnLock ? src + "/yarn.lock",
    yarnNix ? mkYarnNix { inherit yarnLock; },
    offlineCache ? importOfflineCache yarnNix,
    yarnFlags ? defaultYarnFlags,
    yarnPreBuild ? "",
    yarnPostBuild ? "",
    pkgConfig ? {},
    extraBuildInputs ? [],
    publishBinsFor ? null,
    workspaceDependencies ? [], # List of yarnPackages
    packageResolutions ? {},
    ...
  }@attrs:
    let
      yarnLock' = mkYarnLock yarnLock;
      packageJSON' = mkPackageJSON packageJSON;
      package = lib.importJSON packageJSON';
      pname = package.name;
      safeName = reformatPackageName pname;
      version = attrs.version or package.version;
      baseName = unlessNull name "${safeName}-${version}";

      workspaceDependenciesTransitive = lib.unique (
        (lib.flatten (builtins.map (dep: dep.workspaceDependencies) workspaceDependencies))
        ++ workspaceDependencies
      );

      deps = mkYarnModules {
        name = "${safeName}-modules-${version}";
        preBuild = yarnPreBuild;
        postBuild = yarnPostBuild;
        workspaceDependencies = workspaceDependenciesTransitive;
        yarnLock = yarnLock';
        packageJSON = packageJSON';
        inherit pname version offlineCache yarnFlags pkgConfig packageResolutions;
      };

      publishBinsFor_ = unlessNull publishBinsFor [pname];

      linkDirFunction = ''
        linkDirToDirLinks() {
          target=$1
          if [ ! -f "$target" ]; then
            mkdir -p "$target"
          elif [ -L "$target" ]; then
            local new=$(mktemp -d)
            trueSource=$(realpath "$target")
            if [ "$(ls $trueSource | wc -l)" -gt 0 ]; then
              ln -s $trueSource/* $new/
            fi
            rm -r "$target"
            mv "$new" "$target"
          fi
        }
      '';

      workspaceDependencyCopy = lib.concatMapStringsSep "\n"
        (dep: ''
          # ensure any existing scope directory is not a symlink
          linkDirToDirLinks "$(dirname node_modules/${dep.pname})"
          mkdir -p "deps/${dep.pname}"
          tar -xf "${dep}/tarballs/${dep.name}.tgz" --directory "deps/${dep.pname}" --strip-components=1
          if [ ! -e "deps/${dep.pname}/node_modules" ]; then
            ln -sr node_modules "deps/${dep.pname}/node_modules"
          fi
        '')
        workspaceDependenciesTransitive;

    in stdenv.mkDerivation (builtins.removeAttrs attrs ["yarnNix" "pkgConfig" "workspaceDependencies" "packageResolutions"] // {
      inherit src pname;

      name = baseName;

      buildInputs = [ yarn nodejs ] ++ extraBuildInputs;

      node_modules = deps + "/node_modules";

      configurePhase = attrs.configurePhase or ''
        runHook preConfigure

        for localDir in npm-packages-offline-cache node_modules; do
          if [[ -d $localDir || -L $localDir ]]; then
            echo "$localDir dir present. Removing."
            rm -rf $localDir
          fi
        done

        # move convent of . to ./deps/${pname}
        mv $PWD $NIX_BUILD_TOP/temp
        mkdir -p "$PWD/deps/${pname}"
        rm -fd "$PWD/deps/${pname}"
        mv $NIX_BUILD_TOP/temp "$PWD/deps/${pname}"
        cd $PWD

        cp -r $node_modules node_modules
        chmod -R +w node_modules

        ${linkDirFunction}

        linkDirToDirLinks "$(dirname node_modules/${pname})"

        rm node_modules/${pname}
        ln -sr "deps/${pname}" "node_modules/${pname}"
        ln -sr node_modules "deps/${pname}/node_modules"

        ${workspaceDependencyCopy}

        # Help yarn commands run in other phases find the package
        echo "--cwd deps/${pname}" > .yarnrc
        runHook postConfigure
      '';

      # Replace this phase on frontend packages where only the generated
      # files are an interesting output.
      installPhase = attrs.installPhase or ''
        runHook preInstall

        gunzip < $node_modules/../prod.patch.gz | sh /dev/stdin node_modules

        mkdir -p $out/{bin,libexec/${pname}}
        mv node_modules $out/libexec/${pname}/node_modules
        mv deps $out/libexec/${pname}/deps

        node ${./internal/fixup_bin.js} $out/bin $out/libexec/${pname}/node_modules ${lib.concatStringsSep " " publishBinsFor_}

        runHook postInstall
      '';

      fixupPhase = ''
        runHook preFixup

        for x in $(find $out/bin -type f,l -exec realpath {} \;); do
          chmod +x $x
          patchShebangs $x
        done

        runHook postFixup
      '';

      doDist = true;

      distPhase = attrs.distPhase or ''
        # pack command ignores cwd option
        rm -f .yarnrc
        cd $out/libexec/${pname}/deps/${pname}
        mkdir -p $out/tarballs/
        tar --transform 's,^./,package/,' --exclude=node_modules -cf - . | gzip > $out/tarballs/${baseName}.tgz
      '';

      passthru = {
        inherit pname package deps;
        packageJSON = packageJSON';
        workspaceDependencies = workspaceDependenciesTransitive;
      } // (attrs.passthru or {});

      meta = {
        inherit (nodejs.meta) platforms;
        description = package.description or "";
        homepage = package.homepage or "";
        version = package.version or "";
        license = if package ? license then getLicenseFromSpdxId package.license else "";
        mainProgram = builtins.head ((builtins.attrNames package.bin or {}) ++ [pname]);
      } // (attrs.meta or {});
    });

  yarn2nix = mkYarnPackage {
    src =
      let
        src = ./.;

        mkFilter = { dirsToInclude, filesToInclude, root }: path: type:
          let
            inherit (pkgs.lib) any flip elem hasSuffix hasPrefix elemAt splitString;

            subpath = elemAt (splitString "${toString root}/" path) 1;
            spdir = elemAt (splitString "/" subpath) 0;
          in elem spdir dirsToInclude ||
            (type == "regular" && elem subpath filesToInclude);
      in builtins.filterSource
          (mkFilter {
            dirsToInclude = ["bin" "lib"];
            filesToInclude = ["package.json" "yarn.lock"];
            root = src;
          })
          src;

    # yarn2nix is the only package that requires the yarnNix option.
    # All the other projects can auto-generate that file.
    yarnNix = ./yarn.nix;

    # Using the filter above and importing package.json from the filtered
    # source results in an error in restricted mode. To circumvent this,
    # we import package.json from the unfiltered source
    packageJSON = ./package.json;

    yarnFlags = defaultYarnFlags ++ ["--production=true"];

    nativeBuildInputs = [ pkgs.makeWrapper ];

    buildPhase = ''
      source ${./nix/expectShFunctions.sh}

      expectFilePresent ./node_modules/.yarn-integrity

      # check dependencies are installed
      expectFilePresent ./node_modules/@yarnpkg/lockfile/package.json

      # check devDependencies are not installed
      expectFileOrDirAbsent ./node_modules/.bin/eslint
      expectFileOrDirAbsent ./node_modules/eslint/package.json
    '';

    postInstall = ''
      wrapProgram $out/bin/yarn2nix --prefix PATH : "${pkgs.nix-prefetch-git}/bin"
    '';
  };

  fixup_yarn_lock = runCommandLocal "fixup_yarn_lock"
    {
      buildInputs = [ nodejs ];
    } ''
    mkdir -p $out/lib
    mkdir -p $out/bin

    cp ${./lib/urlToName.js} $out/lib/urlToName.js
    cp ${./internal/fixup_yarn_lock.js} $out/bin/fixup_yarn_lock

    patchShebangs $out
  '';
} // lib.optionalAttrs allowAliases {
  # Aliases
  spdxLicense = getLicenseFromSpdxId; # added 2021-12-01
}
