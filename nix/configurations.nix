# The measure of a flake's configurations, shared by relock's impact guard and by the sweep that
# proves the measure stable. One file, so the guard measures exactly what the sweep proved.
#
# A contribution reaches the hosts only through the configurations, so a guard that projects only
# packages and apps drops a real change of a contribution. But measured as they are, they move on
# every commit: ndh sets `system.configurationRevision = self.rev or self.dirtyRev`, and 9 of its 12
# configurations followed the revision. The revision is therefore neutralised before the top level's
# drvPath is taken; `neutralise = false` is the raw measure the sweep compares it with.
{
  outputs,
  neutralise ? true,
}:
let
  measure =
    c:
    (
      if neutralise then
        (c.extendModules {
          modules = [ ({ lib, ... }: { system.configurationRevision = lib.mkForce null; }) ];
        })
      else
        c
    ).config.system.build.toplevel.drvPath;
  each = kind: builtins.mapAttrs (_: measure) (outputs.${kind} or { });
in
{
  nixos = each "nixosConfigurations";
  darwin = each "darwinConfigurations";
}
