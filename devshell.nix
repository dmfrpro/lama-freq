{
  pkgs,
  inputs,
  perSystem,
  flake,
  system,
  ...
}:

(import inputs.devshell { nixpkgs = pkgs; }).mkShell {
  packages =
    with pkgs;
    [
      gcc
      binutils
      coreutils
      time
      git
      (python3.withPackages (packages: [ packages.pytest ]))
      nushell
      nixf-diagnose
      deadnix
      nixfmt
      flake.formatter.${system}
    ]
    ++ perSystem.self.lama-freq.nativeBuildInputs;

  commands = [
    {
      name = "test-all";
      help = "run correctness suites: test-all [core|functional|negative|regression|performance|stress]";
      command = ''exec ${perSystem.self.test}/bin/test-all "$@"'';
    }
    {
      name = "list-tests";
      help = "collect correctness tests with pytest";
      command = ''exec ${perSystem.self.test}/bin/list-tests "$@"'';
    }
    {
      name = "bench";
      help = "measure CPU and memory: bench [performance|stress|stress-full]";
      command = ''exec ${perSystem.self.test}/bin/bench "$@"'';
    }
    {
      name = "analyze";
      help = "inspect frequencies: analyze [Sort|test001|file.bc] [--resources]";
      command = ''exec ${perSystem.self.test}/bin/analyze "$@"'';
    }
    {
      name = "lama-freq";
      help = "run the analyzer directly; use --help for options";
      command = ''exec ${perSystem.self.lama-freq}/bin/lama-freq "$@"'';
    }
  ];

  env = [
    {
      name = "LAMA_DIR";
      value = "${pkgs.lama}/share/Lama";
    }
    {
      name = "LAMA_SRC";
      value = "${pkgs.lama.src}";
    }
    {
      name = "TMPDIR";
      eval = ''"$([ -w /tmp ] && echo /tmp || echo /build)"'';
    }
  ];
}
