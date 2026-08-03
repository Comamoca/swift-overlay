{
  pkgs ? import <nixpkgs> { },
  # Python 3.9 is required by the UBI9 lldb/repl binary on Linux. It is not
  # available in nixos-unstable, so the flake pins an older nixpkgs and
  # passes it here. On Darwin this is ignored.
  python39 ? null,
}:
let
  lib = pkgs.lib;
  stdenv = pkgs.stdenv;
  hashes = lib.importJSON ./swift_hashes.json;

  # Shared metadata for every toolchain derivation.
  swiftMeta = platforms: {
    description = "A general-purpose programming language for building modern software";
    homepage = "https://swift.org";
    license = lib.licenses.asl20;
    mainProgram = "swift";
    inherit platforms;
  };

  getCurrentArch =
    if stdenv.isDarwin then
      "aarch64-darwin"
    else if stdenv.isLinux then
      if stdenv.isAarch64 then "aarch64-linux" else "x86_64-linux"
    else
      throw "Unsupported platform";

  # ---------------------------------------------------------------------------
  # Linux: UBI9 tarball + buildFHSEnv.
  #
  # Layout contract (nixpkgs pkgs/build-support/build-fhsenv-bubblewrap/
  # rootfs-builder/src/main.rs, remap_native_path/remap_multilib_path):
  # only package-relative bin/, sbin/, libexec/, lib/, etc/, opt/, share/,
  # include/ are mapped into the FHS root (lib/ -> /usr/lib64, include/ ->
  # /usr/include, bin/ -> /usr/bin). Anything under a package's usr/ prefix is
  # SILENTLY DROPPED. So the tarball's usr/ prefix must be stripped here:
  # $out/bin, $out/lib, ... This preserves the toolchain's internal relative
  # layout (the swift driver finds ../lib/swift relative to the executable),
  # and $ORIGIN/../lib RPATHs keep resolving via the real store path.
  #
  # No autoPatchelf / patchelf / sysroot farming: the FHS env provides
  # /lib64/ld-linux, glibc headers at /usr/include (via glibc.dev), and the
  # runtime libraries at the sonames the UBI9 build was linked against.
  # ---------------------------------------------------------------------------
  mkSwiftLinux =
    version: archData:
    let
      unwrapped = stdenv.mkDerivation {
        pname = "swift-unwrapped";
        inherit version;

        src = pkgs.fetchurl {
          url = archData.url;
          sha256 = archData.sha256;
        };

        # Tarball extracts to a single top-level dir
        # (swift-<ver>-RELEASE-ubi9[-aarch64]/) containing usr/{bin,lib,...}.
        # The default unpackPhase already cd's into that source root, so the
        # relative `usr/` prefix is stripped here: $out/bin, $out/lib, ...
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r usr/. $out/
          find $out/bin -type f -exec chmod +x {} +
          runHook postInstall
        '';

        # Keep stdenv fixup (strip, patchShebangs) away from the prebuilt
        # toolchain; the FHS env supplies /usr/bin interpreters and libraries.
        dontFixup = true;
      };

      fhs = pkgs.buildFHSEnv {
        pname = "swift-fhs";
        inherit version;

        # Runtime deps of the UBI9 build (apple/swift-docker rhel-ubi/9
        # Dockerfile: git gcc-c++ libcurl libedit libuuid libxml2 ncurses
        # python3 sqlite; plus libcrypt.so.1 via libxcrypt-compat).
        targetPkgs =
          p:
          [
            unwrapped

            p.glibc
            p.glibc.dev # headers land at /usr/include; must be listed explicitly
            p.gcc-unwrapped
            p.gcc-unwrapped.lib # libstdc++.so.6, libgcc_s.so.1
            p.binutils # as/ld (no .lib output exists — do not reference one)
            p.zlib
            p.ncurses # UBI9 ncurses 6.2 -> libncurses.so.6/libtinfo.so.6
            p.libxml2_13 # REQUIRED: provides libxml2.so.2; default libxml2 is 2.15 (soname .so.16)
            p.sqlite
            p.libuuid # alias of util-linuxMinimal; null on darwin — linux-only here
            p.icu
            p.libedit # libedit.so.0; lldb wants UBI9's libedit.so.2 (advisory)
            p.curl
            p.libxcrypt-legacy # libcrypt.so.1; plain libxcrypt is .so.2 (wrong)
            p.python3
            p.tzdata # Foundation TimeZone(identifier:)
            p.gitMinimal # SwiftPM package resolution
          ]
          ++ lib.optionals (python39 != null) [ python39 ]; # lldb/repl on Linux

        profile = ''
          export LD_LIBRARY_PATH=/usr/lib64:/usr/lib
        '';

        # steam-run style dispatcher: the per-tool wrappers below pass
        # /usr/bin/<tool> as $1; SwiftPM children stay inside the namespace.
        runScript = pkgs.writeShellScript "swift-dispatch" ''
          exec "$@"
        '';

        # These are the buildFHSEnv defaults; stated explicitly for clarity.
        unshareUser = false;
        unshareIpc = false;
        unsharePid = false;
        unshareNet = false;
        unshareUts = false;
        unshareCgroup = false;
        extraBwrapArgs = [ ];
      };
    in
    pkgs.runCommand "swift-${version}"
      {
        passthru = {
          inherit unwrapped fhs;
        };
        meta = swiftMeta [
          "x86_64-linux"
          "aarch64-linux"
        ];
      }
      ''
        mkdir -p $out/bin
        for f in ${unwrapped}/bin/*; do
          n="$(basename "$f")"
          cat > "$out/bin/$n" <<WRAPPER
#!${pkgs.runtimeShell}
exec ${fhs}/bin/swift-fhs /usr/bin/$n "\$@"
WRAPPER
          chmod +x "$out/bin/$n"
        done
      '';

  # ---------------------------------------------------------------------------
  # Darwin: unchanged (xar/cpio extraction of the .pkg toolchain).
  # ---------------------------------------------------------------------------
  mkSwiftDarwin =
    version: archData:
    stdenv.mkDerivation {
      pname = "swift";
      inherit version;

      src = pkgs.fetchurl {
        url = archData.url;
        sha256 = archData.sha256;
      };

      nativeBuildInputs = [
        pkgs.xar
        pkgs.cpio
      ];

      unpackPhase = ''
        mkdir -p $TMPDIR/extract
        xar -xf $src -C $TMPDIR/extract
        cd $TMPDIR/extract
        mkdir -p $TMPDIR/payload
        cd $TMPDIR/payload
        cpio -id < $TMPDIR/extract/Payload 2>/dev/null || true
        TOOLCHAIN_DIR=$(ls -d Library/Developer/Toolchains/*.xctoolchain 2>/dev/null | head -1)
        if [ -n "$TOOLCHAIN_DIR" ]; then
          mkdir -p $TMPDIR/swift-out
          cp -r "$TOOLCHAIN_DIR/usr/"* $TMPDIR/swift-out/
        else
          echo "Warning: No .xctoolchain directory found"
          ls -la Library/Developer/ 2>/dev/null || echo "No Library/Developer found"
        fi
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        if [ -d "$TMPDIR/swift-out" ]; then
          cp -r $TMPDIR/swift-out/* $out/
        else
          echo "Warning: swift-out not found, copying current directory"
          cp -r ./* $out/ 2>/dev/null || true
        fi
        find $out/bin -type f -exec chmod +x {} \; 2>/dev/null || true
        runHook postInstall
      '';

      dontStrip = true;

      meta = swiftMeta [ "aarch64-darwin" ];
    };

  mkSwift =
    version: archData:
    if stdenv.isDarwin then
      mkSwiftDarwin version archData
    else
      mkSwiftLinux version archData;

  # Resolve the toolchain for `version` on the current architecture.
  mkSwiftFor =
    version: platforms:
    let
      currentArch = getCurrentArch;
    in
    if builtins.hasAttr currentArch platforms then
      mkSwift version platforms.${currentArch}
    else
      throw "Architecture ${currentArch} not supported for Swift version ${version}";

  # Stable versions in ascending order ("latest" / "nightly" / pre-releases
  # excluded), used to resolve `bin.latest`.
  stableVersions =
    let
      all = builtins.attrNames (builtins.removeAttrs hashes [ "latest" "nightly" ]);
      stable = builtins.filter (v: builtins.match ".*-.*" v == null) all;
    in
    builtins.sort (a: b: builtins.compareVersions a b < 0) stable;

  swiftVersions = builtins.mapAttrs mkSwiftFor (builtins.removeAttrs hashes [ "latest" ]);
in
{
  bin =
    let
      latestVersion =
        if stableVersions == [ ] then
          throw "swift_hashes.json contains no stable Swift versions; run scripts/fetch_swift_releases.py first"
        else
          builtins.elemAt stableVersions (builtins.length stableVersions - 1);
    in
    {
      latest = mkSwiftFor latestVersion hashes.${latestVersion};
    }
    // swiftVersions;
}

