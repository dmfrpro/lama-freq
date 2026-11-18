{
  pkgs,
  perSystem,
  ...
}:

let
  python = pkgs.python3.withPackages (packages: [ packages.pytest ]);
  scriptRoot = ./.;
  runtimeInputs = with pkgs; [
    coreutils
    nushell
    time
    python
    pkgs.lama
    perSystem.self.lama-freq
  ];
  environment = ''
    export LAMA_DIR=${pkgs.lama}/share/Lama
    export LAMA_SRC=${pkgs.lama.src}
    export LAMAC=${pkgs.lama}/bin/lamac
    export LAMAVM=${pkgs.lama}/bin/lamavm
    export ANALYZER=''${ANALYZER:-${perSystem.self.lama-freq}/bin/lama-freq}
    export NU=${pkgs.nushell}/bin/nu
    export TIME=${pkgs.time}/bin/time
    export PYTHONPATH=${scriptRoot}:${perSystem.self.oracle}/bin
    export TABLE_RENDERER=${scriptRoot}/render_tables.nu
  '';
  testApp = pkgs.writeShellApplication {
    name = "test-all";
    inherit runtimeInputs;
    text = ''
      ${environment}
      suite=all
      if [[ $# -gt 0 && $1 != -* ]]; then
        suite=$1
        shift
      fi
      args=(-q)
      case "$suite" in
        all) ;;
        core) args+=(-m 'not stress') ;;
        functional) args+=(-m functional) ;;
        negative) args+=(-m malformed) ;;
        regression | performance | stress) args+=(-m "$suite") ;;
        *) args+=(-m regression -k "$suite") ;;
      esac
      if [[ $# -gt 0 && $1 != -* ]]; then
        args+=(-k "$1")
        shift
      fi
      exec ${python}/bin/python3 -m pytest -c ${../../pytest.ini} "''${args[@]}" ${scriptRoot} "$@"
    '';
  };
  benchApp = pkgs.writeShellApplication {
    name = "bench";
    inherit runtimeInputs;
    text = ''
      ${environment}
      exec ${python}/bin/python3 ${scriptRoot}/bench.py "$@"
    '';
  };
  listTestsApp = pkgs.writeShellApplication {
    name = "list-tests";
    text = ''
      if [[ $# -gt 0 && $1 == --all ]]; then
        shift
      fi
      exec ${testApp}/bin/test-all --collect-only "$@"
    '';
  };
  analyzeApp = pkgs.writeShellApplication {
    name = "analyze";
    inherit runtimeInputs;
    text = ''
      ${environment}
      exec ${python}/bin/python3 ${scriptRoot}/analyze.py "$@"
    '';
  };
in

pkgs.buildEnv {
  name = "lama-freq-test-tools";
  paths = [
    testApp
    benchApp
    listTestsApp
    analyzeApp
  ];
  meta = {
    description = "Run correctness tests, benchmark the analyzer, and inspect Lama units";
    mainProgram = "test-all";
    platforms = [ "x86_64-linux" ];
  };
}
