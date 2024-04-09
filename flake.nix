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
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, gitignore, fenix, naersk, ... }:
    let
      inherit (gitignore.lib) gitignoreSource;

      staticRustFlags = [ "-C" "target-feature=+crt-static" ];

      # Map of map matching supported Nix build systems with Rust
      # cross target systems.
      crossBuildTargets = {
        x86_64-linux = rec {
          x86_64-unknown-linux-gnu = _: { };
          x86_64-unknown-linux-musl = _: {
            CARGO_BUILD_RUSTFLAGS = staticRustFlags;
            # hardeningDisable = [ "all" ];
          };
          x86_64-pc-windows-gnu = pkgs: rec {
            strictDeps = true;
            depsBuildBuild = with pkgs; [
              mingwW64.stdenv.cc
              mingwW64.windows.pthreads
            ];
            TARGET_CC = with pkgs; "${mingwW64.stdenv.cc}/bin/${mingwW64.stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = staticRustFlags ++ [ "-C" "linker=${TARGET_CC}" ];
          };
          aarch64-unknown-linux-gnu = pkgs: rec {
            inherit (x86_64-unknown-linux-gnu pkgs);
            TARGET_CC = with pkgs.aarch64-multiplatform; "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = [ "-C" "linker=${TARGET_CC}" ];
          };
          aarch64-unknown-linux-musl = pkgs: rec {
            inherit (x86_64-unknown-linux-musl pkgs);
            TARGET_CC = with pkgs.aarch64-multiplatform-musl; "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = staticRustFlags ++ [ "-C" "linker=${TARGET_CC}" ];
          };
        };
        x86_64-darwin = rec {
          x86_64-apple-darwin = pkgs: {
            buildInputs = [ pkgs.darwin.apple_sdk.frameworks.Cocoa ];
            NIX_LDFLAGS = "-F${pkgs.darwin.apple_sdk.frameworks.AppKit}/Library/Frameworks -framework AppKit";
          };
          aarch64-apple-darwin = x86_64-apple-darwin;
        };
      };

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
            doCheck = false;
            CARGO_BUILD_TARGET = targetPlatform;
            # cargoTestOptions = opts: opts ++ [ "--lib" ];
          } // package;
        in
        naersk'.buildPackage package';

      mkPackages = buildPlatform:
        let
          pkgs = import nixpkgs { system = buildPlatform; };
          mkPackage' = mkPackage pkgs buildPlatform;
          packages = builtins.mapAttrs (target: package: mkPackage pkgs buildPlatform target (package pkgs.pkgsCross)) (crossBuildTargets.${buildPlatform});
        in
        packages;

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
      supportedSystems = builtins.attrNames crossBuildTargets;
      forEachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      apps = forEachSupportedSystem mkApps;
      packages = forEachSupportedSystem mkPackages;
      devShells = forEachSupportedSystem mkDevShells;
    };
}
