# No NixOS configuration of ours carries the installer's channel: nixpkgs' lxc-container.nix (through
# lxc-instance-common.nix), docker-container.nix and installation-device.nix import installer/cd-dvd/channel.nix, on
# by default, which copies all of nixpkgs (324 MiB) into the image and into the store at every evaluation of the
# system. Off, an evaluation of rke2lab's node image went from 174 s to 13 s (2026-10-26). Each seedmatic flake runs
# this on its own nixosConfigurations; it reads one option per configuration, so it costs seconds, not a system.
# A configuration that does not import channel.nix has no such option and passes. The fix is to import
# nixosModules.lxc-container from this flake instead of nixpkgs' own.
{ pkgs, configurations }:
let
  inherit (pkgs) lib;
  carrying =
    cs:
    builtins.filter (
      n:
      let
        system = cs.${n}.config.system;
      in
      system ? installer && system.installer ? channel && system.installer.channel.enable
    ) (builtins.attrNames cs);
  # The mutants: the same reading must catch a configuration with the channel on, and spare one with it off or
  # without the module, so a green run means the option was read, not skipped.
  probe = carrying {
    on.config.system.installer.channel.enable = true;
    off.config.system.installer.channel.enable = false;
    absent.config.system = { };
  };
  found = carrying configurations;
in
pkgs.runCommand "no-installer-channel" { } (
  if probe != [ "on" ] then
    ''
      echo "FAIL the reading does not tell a channel on from off or absent: caught ${lib.escapeShellArg (toString probe)}"
      exit 1
    ''
  else if found != [ ] then
    ''
      echo "these NixOS configurations carry the installer channel (import nix-flake-commons' nixosModules.lxc-container):"
      printf '  %s\n' ${lib.escapeShellArgs found}
      exit 1
    ''
  else
    "touch $out"
)
