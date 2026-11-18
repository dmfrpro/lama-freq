{ pkgs, inputs, ... }:

let
  mojo-format =
    pkgs.runCommand "mojo-format"
      {
        meta.mainProgram = "mojo-format";
      }
      ''
        mkdir -p "$out/bin"
        cp ${pkgs.lib.getExe' pkgs.mojo-bin "mblack"} "$out/bin/mojo-format"
        chmod u+w "$out/bin/mojo-format"
        substituteInPlace "$out/bin/mojo-format" \
          --replace-fail 'patched_main()' $'if __name__ == "__main__":\n    patched_main()'
      '';
in
inputs.treefmt-nix.lib.mkWrapper pkgs {
  projectRootFile = "flake.nix";

  programs = {
    black = {
      enable = true;
      includes = [
        "packages/test/*.py"
        "packages/oracle/*.py"
      ];
    };
    deadnix = {
      enable = true;
      priority = 10;
    };
    nixf-diagnose = {
      enable = true;
      priority = 20;
    };
    nixfmt = {
      enable = true;
      priority = 30;
    };
  };

  settings.formatter.black.options = [
    "--line-length"
    "120"
  ];
  settings.formatter.mojo = {
    command = pkgs.lib.getExe mojo-format;
    options = [
      "--quiet"
      "--target-version"
      "mojo"
    ];
    includes = [ "packages/lama-freq/src/*.mojo" ];
  };
  settings.formatter.nufmt = {
    command = pkgs.lib.getExe pkgs.nufmt;
    includes = [ "packages/test/*.nu" ];
  };
}
