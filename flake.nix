{
  description = "Reachable-only static frequency analyzer for Lama bytecode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    blueprint = {
      url = "github:numtide/blueprint";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lama-flake = {
      url = "github:dmfrpro/lama-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.blueprint.follows = "blueprint";
    };
  };

  outputs =
    inputs:
    let
      blueprint = inputs.blueprint {
        inherit inputs;
        systems = [ "x86_64-linux" ];
        nixpkgs.config.allowUnfree = true;
        nixpkgs.overlays = [ inputs.lama-flake.overlays.default ];
      };
    in
    blueprint
    // {
      checks = { };
    };
}
