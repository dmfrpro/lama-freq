{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "argmojo";
  version = "0.8.0";

  src = pkgs.fetchFromGitHub {
    owner = "forfudan";
    repo = "argmojo";
    rev = "2ba77c1be364e49fe7db88c724dd0f9a25ed3a44";
    hash = "sha256-YZhGVdiU/+Fz14ANdwCt3Uo1lQD+MJNlpK0X7cBK+ns=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -d "$out/src"
    cp -r src/argmojo "$out/src/"
    install -Dm644 LICENSE "$out/share/licenses/argmojo/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Command-line argument parser library for Mojo";
    homepage = "https://github.com/forfudan/argmojo";
    license = pkgs.lib.licenses.asl20;
  };
}
