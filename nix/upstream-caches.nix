# The upstream binary caches every seedmatic flake shares, as data: each one's URL and, where it signs, its public
# key. No flake carries them as nixConfig any more: no machine of ours takes a flake's nixConfig (ndh dropped
# accept-flake-config), so the trust a nix.conf holds is built by its configuration, which reads them here and
# chooses which it trusts.
{
  nixos = {
    substituter = "https://cache.nixos.org";
    publicKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  };
  # flox pins a nix of its own, which cache.nixos.org does not serve.
  flox = {
    substituter = "https://cache.flox.dev";
    publicKey = "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=";
  };
  # A mirror of cache.nixos.org: what it serves carries cache.nixos.org's signatures, so it has no key of its own.
  aseippFastly = {
    substituter = "https://aseipp-nix-cache.freetls.fastly.net";
  };
}
