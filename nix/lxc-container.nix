# nixpkgs' lxc-container.nix without the installer's channel, for every seedmatic NixOS image that runs as an LXC or
# Incus container. Through lxc-instance-common.nix, the stock profile imports installer/cd-dvd/channel.nix, on by
# default, which copies all of nixpkgs (324 MiB) into the image and into the store at every evaluation of the system:
# an evaluation of rke2lab's node image went from 174 s to 13 s without it (2026-10-26). Our machines evaluate flakes,
# not channels. lib.noInstallerChannel keeps it off.
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/lxc-container.nix" ];
  system.installer.channel.enable = false;
}
