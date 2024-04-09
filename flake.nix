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
          x86_64-unknown-linux-gnu = pkgs: {
            buildInputs = with pkgs; [ zip ];
            postInstall = ''
              cd $out/bin
              mkdir -p {man,completions}
              ./neverest man ./man
              ./neverest completion bash > ./completions/neverest.bash
              ./neverest completion elvish > ./completions/neverest.elvish
              ./neverest completion fish > ./completions/neverest.fish
              ./neverest completion powershell > ./completions/neverest.powershell
              ./neverest completion zsh > ./completions/neverest.zsh
              tar -czf neverest.tgz neverest man completions
              zip -r neverest.zip neverest man completions
            '';
          };
          x86_64-unknown-linux-musl = pkgs: {
            inherit (x86_64-unknown-linux-gnu pkgs) buildInputs postInstall;
            CARGO_BUILD_RUSTFLAGS = staticRustFlags;
          };
          x86_64-pc-windows-gnu = pkgs: rec {
            strictDeps = true;
            depsBuildBuild = with pkgs; [
              (wine.override { wineBuild = "wine64"; })
              zip
              pkgsCross.mingwW64.stdenv.cc
              pkgsCross.mingwW64.windows.pthreads
            ];
            TARGET_CC = with pkgs.pkgsCross; "${mingwW64.stdenv.cc}/bin/${mingwW64.stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = staticRustFlags ++ [ "-C" "linker=${TARGET_CC}" ];
            postInstall = ''
              cd $out/bin
              mkdir -p {man,completions}
              export WINEPREFIX="$(mktemp -d)"
              wine64 ./neverest.exe man ./man
              wine64 ./neverest.exe completion bash > ./completions/neverest.bash
              wine64 ./neverest.exe completion elvish > ./completions/neverest.elvish
              wine64 ./neverest.exe completion fish > ./completions/neverest.fish
              wine64 ./neverest.exe completion powershell > ./completions/neverest.powershell
              wine64 ./neverest.exe completion zsh > ./completions/neverest.zsh
              tar -czf neverest.tgz neverest.exe man completions
              zip -r neverest.zip neverest.exe man completions
            '';
          };
          aarch64-unknown-linux-gnu = pkgs: rec {
            buildInputs = with pkgs; [ qemu zip ];
            TARGET_CC = with pkgs.pkgsCross.aarch64-multiplatform; "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = [ "-C" "linker=${TARGET_CC}" ];
            postInstall = ''
              cd $out/bin
              mkdir -p {man,completions}
              qemu-aarch64 ./neverest man ./man
              qemu-aarch64 ./neverest completion bash > ./completions/neverest.bash
              qemu-aarch64 ./neverest completion elvish > ./completions/neverest.elvish
              qemu-aarch64 ./neverest completion fish > ./completions/neverest.fish
              qemu-aarch64 ./neverest completion powershell > ./completions/neverest.powershell
              qemu-aarch64 ./neverest completion zsh > ./completions/neverest.zsh
              tar -czf neverest.tgz neverest man completions
              zip -r neverest.zip neverest man completions
            '';
          };
          aarch64-unknown-linux-musl = pkgs: rec {
            inherit (aarch64-unknown-linux-gnu pkgs) buildInputs postInstall;
            TARGET_CC = with pkgs.pkgsCross.aarch64-multiplatform-musl; "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
            CARGO_BUILD_RUSTFLAGS = staticRustFlags ++ [ "-C" "linker=${TARGET_CC}" ];
          };
        };
        x86_64-darwin = rec {
          x86_64-apple-darwin = pkgs: {
            buildInputs = with pkgs; [ zip darwin.apple_sdk.frameworks.Cocoa ];
            NIX_LDFLAGS = with pkgs.darwin.apple_sdk.frameworks; "-F${AppKit}/Library/Frameworks -framework AppKit";
            postInstall = ''
              cd $out/bin
              mkdir -p {man,completions}
              ./neverest man ./man
              ./neverest completion bash > ./completions/neverest.bash
              ./neverest completion elvish > ./completions/neverest.elvish
              ./neverest completion fish > ./completions/neverest.fish
              ./neverest completion powershell > ./completions/neverest.powershell
              ./neverest completion zsh > ./completions/neverest.zsh
              tar -czf neverest.tgz neverest man completions
              zip -r neverest.zip neverest man completions
            '';
          };
          aarch64-apple-darwin = pkgs: rec {
            buildInputs = with pkgs; [ zip darwin.apple_sdk.frameworks.Cocoa ];
            NIX_LDFLAGS = with pkgs; "-F${darwin.apple_sdk.frameworks.AppKit}/Library/Frameworks -framework AppKit";
            # TARGET_CC = with pkgs.pkgsCross; "${aarch64-darwin.stdenv.cc}/bin/${aarch64-darwin.stdenv.cc.targetPrefix}cc";
            # CARGO_BUILD_RUSTFLAGS = [ "-C" "linker=${TARGET_CC}" ];
            postInstall = ''
              cd $out/bin
              mkdir -p {man,completions}
              qemu-aarch64 ./neverest man ./man
              qemu-aarch64 ./neverest completion bash > ./completions/neverest.bash
              qemu-aarch64 ./neverest completion elvish > ./completions/neverest.elvish
              qemu-aarch64 ./neverest completion fish > ./completions/neverest.fish
              qemu-aarch64 ./neverest completion powershell > ./completions/neverest.powershell
              qemu-aarch64 ./neverest completion zsh > ./completions/neverest.zsh
              tar -czf neverest.tgz neverest man completions
              zip -r neverest.zip neverest man completions
            '';
          };
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
          } // package;
        in
        naersk'.buildPackage package';

      mkPackages = buildPlatform:
        let
          pkgs = import nixpkgs { system = buildPlatform; };
          packages = builtins.mapAttrs (target: package: mkPackage pkgs buildPlatform target (package pkgs)) (crossBuildTargets.${buildPlatform});
        in
        packages;

      mkApp = drv:
        let
          exePath = drv.passthru.exePath or "/bin/neverest";
        in
        {
          type = "app";
          program = "${drv}${exePath}";
        };

      mkApps = buildPlatform:
        let
          pkgs = import nixpkgs { system = buildPlatform; };
          apps = builtins.mapAttrs (target: package: mkApp self.packages.${buildPlatform}.${target}) (crossBuildTargets.${buildPlatform});
        in
        apps;
      supportedSystems = builtins.attrNames crossBuildTargets;
      forEachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      apps = forEachSupportedSystem mkApps;
      packages = forEachSupportedSystem mkPackages;
      devShells = forEachSupportedSystem mkDevShells;
    };
}
