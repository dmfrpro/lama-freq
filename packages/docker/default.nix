{ pkgs, flake, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  runtime = pkgs.buildEnv {
    name = "lama-freq-docker-runtime";
    paths = [
      pkgs.bashInteractive
      flake.packages.${system}.lama-freq
      flake.packages.${system}.test
    ];
  };
in

pkgs.dockerTools.buildNixShellImage {
  name = "dmfrpro/lama-freq";
  tag = "latest";
  shell = "${runtime}/bin/bash";
  drv = flake.devShells.${system}.default // {
    outputs = [ "out" ];
  };
}
