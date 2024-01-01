{
  description = "CLI to manage emails";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, gitignore, fenix, naersk, ... }:
    let
      inherit (gitignore.lib) gitignoreSource;

      mkToolchain = import ./rust-toolchain.nix fenix;

      mkDevShells = buildPlatform:
        let
          pkgs = import nixpkgs { system = buildPlatform; };
          rust-toolchain = mkToolchain.fromFile { system = buildPlatform; };
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [ pkg-config ];
            buildInputs = with pkgs; [
              # Nix
              rnix-lsp
              nixpkgs-fmt

              # Rust
              rust-toolchain

              # Notmuch
              notmuch

              # GPG
              gnupg
              gpgme
            ];
          };
        };

      mkPackage = pkgs: buildPlatform: targetPlatform: package:
        let
          toolchain = mkToolchain.fromTarget {
            inherit pkgs buildPlatform targetPlatform;
          };
          naersk' = naersk.lib.${buildPlatform}.override {
            cargo = toolchain;
            rustc = toolchain;
          };
          package' = {
            name = "himalaya";
            src = gitignoreSource ./.;
            overrideMain = _: {
              postInstall = ''
                mkdir -p $out/share/applications/
                cp assets/himalaya.desktop $out/share/applications/
              '';
            };
            doCheck = true;
            cargoTestOptions = opts: opts ++ [ "--lib" ];
          } // pkgs.lib.optionalAttrs (!isNull targetPlatform) {
            CARGO_BUILD_TARGET = targetPlatform;
          } // package;
        in
        naersk'.buildPackage package';

      mkPackages = buildPlatform:
        let
          pkgs = import nixpkgs { system = buildPlatform; };
          mkPackageWithTarget = mkPackage pkgs buildPlatform;
          defaultPackage = mkPackage pkgs buildPlatform null { };
        in
        {
          default = defaultPackage;
          linux = defaultPackage;
          macos = mkPackageWithTarget null (with pkgs.darwin.apple_sdk.frameworks; {
            # CARGO_BUILD_RUSTFLAGS = "-C panic=abort";
            NIX_LDFLAGS = "-F${AppKit}/Library/Frameworks -framework AppKit";
            # CARGO_BUILD_RUSTFLAGS = "- target-feature=+crt-static";
            buildInputs = [ Cocoa CoreFoundation ];
            # preConfigure = ''
            #   export NIX_LDFLAGS="-F${CoreFoundation}/Library/Frameworks -framework CoreFoundation $NIX_LDFLAGS"
            # '';
          });
          musl = mkPackageWithTarget "x86_64-unknown-linux-musl" (with pkgs.pkgsStatic; {
            CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
            SQLITE3_STATIC = 1;
            SQLITE3_LIB_DIR = "${sqlite.out}/lib";
            hardeningDisable = [ "all" ];
          });
          # FIXME: bzlip: fatal error: windows.h: No such file or directory
          # May be related to SQLite.
          windows = mkPackageWithTarget "x86_64-pc-windows-gnu" {
            strictDeps = true;
            depsBuildBuild = with pkgs.pkgsCross.mingwW64; [
              stdenv.cc
              windows.pthreads
            ];
          };
        };

      mkApp = drv: flake-utils.lib.mkApp {
        inherit drv;
        name = "himalaya";
      };

      mkApps = buildPlatform: {
        default = mkApp self.packages.${buildPlatform}.default;
        linux = mkApp self.packages.${buildPlatform}.linux;
        macos = mkApp self.packages.${buildPlatform}.macos;
        musl = mkApp self.packages.${buildPlatform}.musl;
        windows =
          let
            pkgs = import nixpkgs { system = buildPlatform; };
            wine = pkgs.wine.override { wineBuild = "wine64"; };
            himalaya = self.packages.${buildPlatform}.windows;
            app = pkgs.writeShellScriptBin "himalaya" ''
              export WINEPREFIX="$(mktemp -d)"
              ${wine}/bin/wine64 ${himalaya}/bin/himalaya.exe $@
            '';
          in
          mkApp app;
      };

    in
    flake-utils.lib.eachDefaultSystem (system: {
      devShells = mkDevShells system;
      packages = mkPackages system;
      apps = mkApps system;
    });
}
