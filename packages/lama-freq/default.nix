{
  pkgs,
  perSystem,
  ...
}:

let
  inherit (pkgs) lib;
  argmojo = perSystem.self.argmojo;
in

pkgs.stdenv.mkDerivation {
  pname = "lama-freq";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  strictDeps = true;

  nativeBuildInputs = [
    pkgs.mojo-bin
    argmojo
  ];

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    mkdir -p build
    mojo build -I src -I ${argmojo}/src src/main.mojo -o build/lama-freq
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./build/lama-freq --help > /dev/null
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/lama-freq "$out/bin/lama-freq"
    install -Dm644 ${argmojo}/share/licenses/argmojo/LICENSE "$out/share/licenses/lama-freq/argmojo.LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Readability-oriented Mojo reachable instruction frequency analyzer";
    mainProgram = "lama-freq";
    platforms = [ "x86_64-linux" ];
  };
}
