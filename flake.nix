{
  description = "Server NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default =
      self.nixosConfigurations.nixos.config.system.build.toplevel;

    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ({ pkgs, ... }: {
          environment.systemPackages = with pkgs; [ git gnupg ];
        })
        { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
      ];
    };
  };
}

