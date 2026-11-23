{
  description = "Standalone NixOS QEMU microVM configuration for MindRoom";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ragenix,
      microvm,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.mindroom = lib.nixosSystem {
        inherit system;
        modules = [
          ragenix.nixosModules.default
          microvm.nixosModules.microvm
          ./hosts/mindroom/default.nix
          ./modules/microvm-guest.nix
        ];
      };

      packages.${system} =
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # QEMU microVM runner (build with `--out-link runner` from a private state dir; see AGENTS.md).
          runner = self.nixosConfigurations.mindroom.config.microvm.declaredRunner;
        in
        {
          default = runner;
          mindroom-microvm = runner;
          # The pinned ragenix CLI from nixpkgs, used by scripts/bootstrap-secrets.sh.
          # (Upstream ragenix's flake pins an older rust-overlay that breaks on current nixpkgs.)
          inherit (pkgs) ragenix;
        };

      # Eval-only check: `nix flake check` instantiates the microVM runner and
      # guest system (catching every Nix-level error) without building their
      # multi-GB closures. unsafeDiscardOutputDependency keeps the .drv
      # reference from pulling in build outputs.
      checks.${system} =
        let
          pkgs = nixpkgs.legacyPackages.${system};
          drvPath = builtins.unsafeDiscardOutputDependency self.packages.${system}.default.drvPath;
        in
        {
          mindroom = pkgs.runCommand "mindroom-eval-check" { } ''
            echo ${drvPath} > $out
          '';
        };
    };
}
