{
  description = "Yarn to Nix";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";

    utils.url = "github:numtide/flake-utils";
    utils.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { utils, nixpkgs, ... }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs.lib) makeOverridable;
        defaultArgs = { inherit pkgs; };
        packages.default = makeOverridable (a: (import ./. a).yarn2nix) defaultArgs;
        lib = makeOverridable (import ./.) defaultArgs;
      in
      { inherit packages lib; }
    );
}
