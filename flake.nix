{
  description = "Demo dev shell with vim, git, gnupg, and curl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tools = with pkgs; [ vim git gnupg curl ];
      in
      {
        # `nix develop` drops you into a shell with all four tools
        devShells.default = pkgs.mkShell {
          packages = tools;
          shellHook = ''
            echo "Tools available: vim, git, gnupg, curl"
          '';
        };

        # `nix build` produces a single environment containing all four
        packages.default = pkgs.buildEnv {
          name = "demo-tools";
          paths = tools;
        };
      });
}
