fenix:

let
  file = ./rust-toolchain.toml;
  sha256 = "+syqAd2kX8KVa8/U2gz3blIQTTsYYt3U63xBWaGOSc8=";
in
{
  fromFile = { system }: fenix.packages.${system}.fromToolchainFile {
    inherit file sha256;
  };

  fromTarget = { pkgs, buildPlatform, targetPlatform ? null }:
    let
      inherit ((pkgs.lib.importTOML file).toolchain) channel;
      fenixToolchain = fenix.packages.${buildPlatform};
      rustToolchain = fenix.packages.${buildPlatform}.fromToolchainName {
        inherit sha256;
        name = channel;
      };
    in
    if
      isNull targetPlatform
    then
      rustToolchain
    else
      fenixToolchain.combine [
        rustToolchain.rustc
        rustToolchain.cargo
        fenixToolchain.targets.${targetPlatform}.fromToolchainFile {inherit file sha256;}
      ];
}
