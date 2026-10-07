{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      #      "https://kclejeune.cachix.org"
      "https://cache.flox.dev"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      #      "kclejeuneachix.org-1:fOCrECygdFZKbMxHClhiTS6oowOkJ/I/dh9q9b1I4ko="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];
  };

  inputs = {
    flake-compat.url = "github:edolstra/flake-compat";
    flake-utils.url = "github:numtide/flake-utils";

    nix.url = "github:NixOS/nix/2.32.4";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    impermanence.url = "github:nix-community/impermanence";
      
    disko = {
      url = "github:nix-community/disko/v1.12.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  
    nix-snapshotter = {
      url = "github:pdtpartners/nix-snapshotter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    chromium-bin = {
      url = "github:lrworth/chromium-bin-flake";
    };

    lix-module = {
      url = "https://git.lix.systems/lix-project/nixos-module/archive/2.93.0.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/0";

    darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flox = {
      url = "github:flox/flox?branch=main";
#     inputs.nixpkgs.follows = "nixpkgs";
    };

    nvfetcher.url = "github:berberman/nvfetcher";

    treefmt-nix.url = "github:numtide/treefmt-nix/main";

    extra-container = {
      flake = true;
      url = "github:erikarvstedt/extra-container";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # nxmatic 

    bird = {
      flake = true;
      url = "github:nxmatic/bird?ref=hotfix/v2.15.1-nix-darwin";
    };

    maven-mvnd = {
      flake = true;
      url = "github:nxmatic/nix-maven-mvnd/develop";
    };

  };

  # The aggregator's first outputs: the shared `relock` tool, and this repo's own use of it.
  #
  # `lib.mkRelockApp` is here because this is the ROOT every seedmatic flake already consumes — a
  # tool the whole chain shares belongs where the whole chain already points, rather than in one
  # leaf the others would have to take a new edge to. And this repo is a USER of it, not only its
  # host: it has third-party inputs of its own to bump, and relock measures an aggregator's impact
  # on the revisions it locks, since its inputs are what it exports.
  #
  # `consumers` stays empty on purpose: from here, the closure that needs reconciling is the forward
  # one — the inputs. The eight repos that follow this one pick a bump up at their own relock.
  outputs = { self, nixpkgs, flake-utils, home-manager, ... }:
    {
      lib.mkRelockApp = import ./nix/relock.nix;
    }
    // flake-utils.lib.eachDefaultSystem (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
      # Behaviour tests for relock, run by `nix flake check`. They cover what shellcheck — already a
      # gate of every build — cannot see: the failure paths, where every defect this script had was
      # a silence. The instance under test is built by the SAME factory, with aliases and a consumer
      # declared so those paths are exercised populated rather than empty.
      checks.relock =
        let
          underTest = self.lib.mkRelockApp {
            inherit pkgs;
            name = "t";
            slug = "seedmatic/t";
            url = "file:///nonexistent/seedmatic/t.git";
            consumers = [ "fake:consumer" ];
            aliases = { plans = "regen-dataplan"; };
            pushFirstBranch = "first";
          };
          # The same repo's OTHER flake, the one on an orphan branch.
          underTestOnBranch = self.lib.mkRelockApp {
            inherit pkgs;
            name = "t-orphan";
            slug = "seedmatic/t";
            url = "file:///nonexistent/seedmatic/t.git";
            branch = "orphan";
          };
        in
        pkgs.runCommand "relock-bats" {
          nativeBuildInputs = [ pkgs.bats pkgs.bash pkgs.coreutils pkgs.gnused pkgs.git pkgs.jq ];
          RELOCK = "${underTest}/bin/relock";
          RELOCK_ON_BRANCH = "${underTestOnBranch}/bin/relock";
        } ''
          export HOME=$TMPDIR
          bats --print-output-on-failure ${./nix/relock.bats}
          touch $out
        '';

      apps.relock = {
        type = "app";
        program = "${
          self.lib.mkRelockApp {
            inherit pkgs;
            name = "nix-flake-commons";
            slug = "seedmatic/nix-flake-commons";
            url = "https://github.com/seedmatic/nix-flake-commons.git";
          }
        }/bin/relock";
        meta.description = "Reconcile THIS repo's locks: bump each input, DROP any bump that moves nothing it exports, push";
      };
    });

}
