{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
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
              python312Packages.python-lsp-server
            ];
            shellHook = '''';
          };
        }
      );

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          swiftPackage = import ./swift.nix { inherit pkgs; };
          swift = swiftPackage.bin.latest;
        in
        {
          default = swift;
        }
      );

      overlays = {
        default = final: prev: {
          swift = import ./swift.nix { pkgs = prev; };
        };
      };
    };
}
