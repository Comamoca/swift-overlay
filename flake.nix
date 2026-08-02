{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nixpkgs-python39.url = "github:nixos/nixpkgs?ref=nixos-24.05";
  };

  outputs =
    { self, nixpkgs, nixpkgs-python39 }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nil
              pyright
              ruff
            ];
            shellHook = '''';
          };
        }
      );

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Python 3.9 is required by the UBI9 lldb/repl binary on Linux.
          # nixos-unstable no longer ships it, so pull it from an older
          # nixpkgs pin that still provides it. Unused on Darwin.
          python39 = nixpkgs-python39.legacyPackages.${system}.python39 or null;
          swiftPackage = import ./swift.nix { inherit pkgs python39; };
          swift = swiftPackage.bin.latest;
        in
        {
          default = swift;
        }
      );

      overlays = {
        default = final: prev:
          let
            python39 = nixpkgs-python39.legacyPackages.${prev.system}.python39 or null;
          in
          {
            swift = import ./swift.nix { pkgs = prev; inherit python39; };
          };
      };
    };
}
