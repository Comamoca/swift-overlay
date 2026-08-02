<div align="center">

![Last commit](https://img.shields.io/github/last-commit/Comamoca/swift-overlay?style=flat-square)
![Repository Stars](https://img.shields.io/github/stars/Comamoca/swift-overlay?style=flat-square)
![Issues](https://img.shields.io/github/issues/Comamoca/swift-overlay?style=flat-square)
![Open Issues](https://img.shields.io/github/issues-raw/Comamoca/swift-overlay?style=flat-square)
![Bug Issues](https://img.shields.io/github/issues/Comamoca/swift-overlay/bug?style=flat-square)

# swift-overlay

A Nix overlay providing [Swift](https://swift.org/) toolchains for multiple versions and platforms.

</div>

## ✨ Features

- 🚀 Latest Swift releases with automatic updates
- 🏗️ Multiple architecture support (x86_64/aarch64 Linux, aarch64 macOS)
- 📦 Easy integration with Nix flakes and traditional overlays
- 🔄 Binary distributions for faster installation
- 🔧 NixOS-compatible via buildFHSEnv (FHS-wrapped UBI9 toolchain on Linux)

## 🚀 Usage

### With Nix Flakes

Add this overlay to your flake inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    swift-overlay.url = "github:Comamoca/swift-overlay";
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
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
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              inputs.swift-overlay.overlays.default
            ];
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              pkgs.swift.bin.latest # Latest version
            ];
            shellHook = '''';
          };
        }
      );
    };
}
```

### Direct Usage

```sh
# Run the latest version
nix run github:Comamoca/swift-overlay

# Use in a shell
nix shell github:Comamoca/swift-overlay
```

### Build cache

swift-overlay provides a [cache](https://app.cachix.org/cache/swift-overlay#pull) via cachix.
In environments with cachix cli, you can use the cache during builds with the following command:

```sh
cachix use swift-overlay
```

## 🏗️ Supported Platforms

- `aarch64-darwin`
- `aarch64-linux`
- `x86_64-linux`

## 📋 Version & Platform Compatibility

| Version | aarch64-darwin | aarch64-linux | x86_64-linux |
|---------|---------|---------|---------|
| `6.3.3` | ✅ | ✅ | ✅ |


## ⛏️ Development

### Prerequisites

```sh
nix develop
# or
direnv allow
```

### How it works

- Linux: the official Swift UBI9 (Red Hat Universal Base Image 9) tarball is
  fetched and placed into a `buildFHSEnv` environment. This gives the bundled
  Clang and linker the `/usr/include`, `/usr/lib` and `/usr/lib64` layout they
  expect, so the previous `autoPatchelfHook` + sysroot/SONAME workarounds are no
  longer needed. Every executable in the toolchain is wrapped to run inside the
  FHS namespace, so `swiftpm` can spawn `swiftc`, `swift-frontend`, `clang` and
  `lld` by absolute path and still find the right libraries.
- macOS: the `.pkg` toolchain is still extracted with `xar` + `cpio` and used
  directly.

### Quality Assurance

```sh
# Run the host-side QA suite (this is not a flake check because
# bubblewrap cannot create user namespaces inside the nix build sandbox).
scripts/qa.sh
```

### Updating Releases

```sh
cd scripts
python fetch_swift_releases.py
```

This will update `swift_hashes.json` with the latest Swift releases and their checksums.

### Building Manually

```sh
# Build the latest version
nix build

# Show flake metadata
nix flake show
```

## 📜 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [Swift](https://swift.org/) - A general-purpose programming language for building modern software
- The Nix community for excellent tooling and patterns