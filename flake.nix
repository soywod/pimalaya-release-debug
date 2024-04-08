{
  description = "CLI to synchronize and backup emails";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
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
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, gitignore, fenix, naersk, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
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
              nativeBuildInputs = with pkgs; [
                pkg-config
              ];
              buildInputs = with pkgs; [
                # Nix
                # rnix-lsp
                nixpkgs-fmt

                # Rust
                rust-toolchain
                cargo-watch

                # OpenSSL
                openssl.dev

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
              name = "neverest";
              src = gitignoreSource ./.;
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
            mkPackage' = mkPackage pkgs buildPlatform;
          in
          rec {
            default = if pkgs.stdenv.isDarwin then macos else linux;
            linux = mkPackage' null { };
            linux-musl = mkPackage' "x86_64-unknown-linux-musl" (with pkgs.pkgsStatic; {
              CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
              hardeningDisable = [ "all" ];
            });
            macos = mkPackage' null (with pkgs.darwin.apple_sdk.frameworks; {
              # NOTE: needed to prevent error Undefined symbols
              # "_OBJC_CLASS_$_NSImage" and
              # "_LSCopyApplicationURLsForBundleIdentifier"
              NIX_LDFLAGS = "-F${AppKit}/Library/Frameworks -framework AppKit";
              buildInputs = [ Cocoa ];
            });
            windows = mkPackage' "x86_64-pc-windows-gnu" (rec {
              strictDeps = true;
              doCheck = false;

              TARGET_CC = with pkgs.pkgsCross; "${mingwW64.stdenv.cc}/bin/${mingwW64.stdenv.cc.targetPrefix}cc";
              CARGO_BUILD_RUSTFLAGS = [
                "-C"
                "target-feature=+crt-static"

                # -latomic is required to build openssl-sys for armv6l-linux, but
                # it doesn't seem to hurt any other builds.
                "-C"
                "link-args=-static -latomic"

                # https://github.com/rust-lang/cargo/issues/4133
                "-C"
                "linker=${TARGET_CC}"
              ];
              depsBuildBuild = with pkgs.pkgsCross; [
                mingwW64.stdenv.cc
                mingwW64.windows.pthreads
              ];
            });
          };

        mkApp = drv:
          let exePath = drv.passthru.exePath or "/bin/neverest";
          in
          {
            type = "app";
            program = "${drv}${exePath}";
          };

        mkApps = buildPlatform:
          let
            pkgs = import nixpkgs { system = buildPlatform; };
          in
          rec {
            default = if pkgs.stdenv.isDarwin then macos else linux;
            linux = mkApp self.packages.${buildPlatform}.linux;
            linux-musl = mkApp self.packages.${buildPlatform}.linux-musl;
            macos = mkApp self.packages.${buildPlatform}.macos;
            windows =
              let
                wine = pkgs.wine.override { wineBuild = "wine64"; };
                neverest = self.packages.${buildPlatform}.windows;
                app = pkgs.writeShellScriptBin "neverest" ''
                  export WINEPREFIX="$(mktemp -d)"
                  ${wine}/bin/wine64 ${neverest}/bin/neverest.exe $@
                '';
              in
              mkApp app;
          };
      in
      {
        apps = mkApps system;
        packages = mkPackages system;
        devShells = mkDevShells system;
      });
}
