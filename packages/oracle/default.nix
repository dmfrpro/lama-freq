{ pkgs, ... }:

pkgs.writers.writePython3Bin "oracle.py" {
  flakeIgnore = [
    "E203"
    "E501"
    "W503"
  ];
} (builtins.readFile ./oracle.py)
