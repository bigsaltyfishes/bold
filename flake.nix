{
  description = "Bold linker";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      rec {
        commonInputs = with pkgs; [ zig_0_15 ];

        tracy-version = "0.10";
        tracy-src = pkgs.fetchFromGitHub {
          owner = "wolfpld";
          repo = "tracy";
          rev = "v${tracy-version}";
          hash = "sha256-DN1ExvQ5wcIUyhMAfiakFbZkDsx+5l8VMtYGvSdboPA=";
        };

        packages.default = packages.bold;
        packages.bold = pkgs.stdenv.mkDerivation {
          name = "bold";
          version = "master";
          src = ./.;
          nativeBuildInputs = commonInputs;
          dontConfigure = true;
          dontInstall = true;
          doCheck = false;
          postPatch = ''
            mkdir -p .cache
            ln -s ${pkgs.callPackage ./build.zig.zon.nix { }} $(pwd)/.cache/p
          '';
          buildPhase = ''
            zig build install -Doptimize=ReleaseFast --prefix $out --cache-dir $(pwd)/.zig-cache --global-cache-dir $(pwd)/.cache
          '';
        };

        devShells.default = pkgs.mkShell {
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=$HOME/.cache/zig
          '';
          buildInputs =
            commonInputs
            ++ (with pkgs; [
              zls_0_15
              zig_0_15
              zon2nix
              tracy
              hyperfine
            ]);

          TRACY_PATH = "${tracy-src}/public";
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;
      }
    );
}
