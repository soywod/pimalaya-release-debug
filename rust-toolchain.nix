fenix:

let
  file = ./rust-toolchain.toml;
  sha256 = "GJUrf6Vy0KPq4sVoi6a0lbQAJpiJiTaG6Y7h0Voz5j4=";
in
{
  fromFile = { system }: fenix.packages.${system}.fromToolchainFile {
    inherit file sha256;
  };

  fromTarget = { pkgs, buildPlatform, targetPlatform ? null }:
    let
      inherit ((pkgs.lib.importTOML file).toolchain) channel;
      toolchain = fenix.packages.${buildPlatform};
    in
    if
      isNull targetPlatform
    then
      fenix.packages.${buildPlatform}.toolchainOf { inherit channel sha256; }
    else
      toolchain.combine [
        toolchain.${channel}.rustc
        toolchain.${channel}.cargo
        toolchain.targets.${targetPlatform}.${channel}.rust-std
      ];
}
