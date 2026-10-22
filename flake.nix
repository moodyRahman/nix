{
  description = "Server NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nix.settings.trusted-users = [ "moody" ];
    nix.settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "moody:BC6jelA0uKMl4YKwvbprhDslYTygdpj24MyM1olCTR8="
    ];

    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;
    packages.x86_64-linux.default = self.nixosConfigurations.nixos.config.system.build.toplevel;

    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ({ pkgs, ... }: {
          environment.systemPackages = with pkgs; [
            git
            gnupg
            vim
          ];
        })
        { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
      ];
    };
  };
}
