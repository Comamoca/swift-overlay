{
  pkgs ? import <nixpkgs> { },
}:
let
  hashes = pkgs.lib.importJSON ./swift_hashes.json;

  mkSwiftBinary =
    version: archData:
    pkgs.stdenv.mkDerivation rec {
      pname = "swift";
      inherit version;

      src = pkgs.fetchurl {
        url = archData.url;
        sha256 = archData.sha256;
      };

      nativeBuildInputs =
        if pkgs.stdenv.isLinux then [ pkgs.autoPatchelfHook pkgs.makeWrapper ]
        else if pkgs.stdenv.isDarwin then [ pkgs.xar pkgs.cpio ]
        else [ ];

      buildInputs =
        if pkgs.stdenv.isLinux then [
          pkgs.stdenv.cc.cc
          pkgs.glibc
          pkgs.zlib
          pkgs.icu
          pkgs.curl
          pkgs.openssl
          pkgs.libxml2.out  # libxml2 has bin as default output, libraries are in out
          pkgs.sqlite
          pkgs.ncurses
          pkgs.libedit
          pkgs.libuuid
          pkgs.python312
        ] else [ ];

      autoPatchelfIgnoreMissing = true;

      # Pre-install phase: create sysroot compatible CRT/LIB directories
      # Swift's clang/LLD expects standard FHS paths like /lib, /usr/lib
      # On NixOS these don't exist, so we provide them via the sysroot
      preFixupPhases = if pkgs.stdenv.isLinux then [ "linkSysroot" ] else [ ];

      linkSysroot = ''
        GLIBC_LIB="${pkgs.glibc.out}/lib"
        GCC_CRT="${pkgs.stdenv.cc.cc}/lib/gcc/*/*"
        GCC_LIB="${pkgs.stdenv.cc.cc.lib}/lib"

        # Copy CRT files from glibc into $out/lib
        cp -L "$GLIBC_LIB"/crt1.o $out/lib/
        cp -L "$GLIBC_LIB"/crti.o $out/lib/
        cp -L "$GLIBC_LIB"/crtn.o $out/lib/
        # Create Scrt1.o for PIE executable support
        ln -sf crt1.o $out/lib/Scrt1.o

        # Copy GCC CRT and libgcc from GCC arch-specific directory
        for d in $GCC_CRT; do
          cp -L "$d"/crtbegin*.o $out/lib/ 2>/dev/null || true
          cp -L "$d"/crtend*.o $out/lib/ 2>/dev/null || true
          cp -L "$d"/libgcc*.a $out/lib/ 2>/dev/null || true
        done

        # Copy libgcc_s from GCC lib output
        cp -L "$GCC_LIB"/libgcc* $out/lib/ 2>/dev/null || true

        # Copy glibc libraries
        cp -L "$GLIBC_LIB"/libc.* $out/lib/ 2>/dev/null || true
        cp -L "$GLIBC_LIB"/libm.* $out/lib/ 2>/dev/null || true
        cp -L "$GLIBC_LIB"/libdl.* $out/lib/ 2>/dev/null || true
        cp -L "$GLIBC_LIB"/libpthread.* $out/lib/ 2>/dev/null || true
      '';

      postFixup =
        if pkgs.stdenv.isLinux then ''
          # Create compat symlinks for mismatched SONAMEs between Nixpkgs and Swift's Ubuntu base
          ln -sf ${pkgs.libxml2.out}/lib/libxml2.so.16 $out/lib/libxml2.so.2 2>/dev/null || true
          ln -sf ${pkgs.libedit}/lib/libedit.so.0 $out/lib/libedit.so.2 2>/dev/null || true

          # Add $out/lib to RPATH for compat symlinks and Swift libraries
          for f in $(find $out -type f -executable 2>/dev/null; find $out/lib -name "*.so*" -type f 2>/dev/null); do
            patchelf --add-rpath "$out/lib" "$f" 2>/dev/null || true
          done

          # Create ld -> lld symlink for clang
          ln -sf lld $out/bin/ld 2>/dev/null || true

          # Wrap swiftc with sysroot pointing to $out (contains CRT files)
          wrapProgram $out/bin/swiftc \
            --prefix PATH : $out/bin \
            --add-flags "-Xcc" --add-flags "--sysroot=$out" \
            --add-flags "-Xlinker" --add-flags "-L$out/lib"

          # Wrap swift for environment
          wrapProgram $out/bin/swift \
            --prefix PATH : $out/bin \
            --set SWIFT_CC "$out/bin/clang" \
            --set CC "$out/bin/clang" \
            --set CXX "$out/bin/clang++"
        '' else "";

      unpackPhase =
        if pkgs.stdenv.isDarwin then
          ''
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
          ''
        else
          ''
            tar -xf $src
            SWIFT_DIR=$(ls -d */usr 2>/dev/null | head -1)
            if [ -n "$SWIFT_DIR" ]; then
              mkdir -p $TMPDIR/swift-out
              cp -r "$SWIFT_DIR/"* $TMPDIR/swift-out/
            else
              ALT_DIR=$(ls -d swift-*/usr 2>/dev/null | head -1)
              if [ -n "$ALT_DIR" ]; then
                mkdir -p $TMPDIR/swift-out
                cp -r "$ALT_DIR/"* $TMPDIR/swift-out/
              fi
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

      meta = with pkgs.lib; {
        description = "A general-purpose programming language for building modern software";
        homepage = "https://swift.org";
        license = licenses.asl20;
        mainProgram = "swift";
        platforms = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];
      };
    };

  getCurrentArch =
    if pkgs.stdenv.isDarwin then
      if pkgs.stdenv.isAarch64 then "aarch64-darwin" else "x86_64-darwin"
    else if pkgs.stdenv.isLinux then
      if pkgs.stdenv.isAarch64 then "aarch64-linux" else "x86_64-linux"
    else
      throw "Unsupported platform";

  swiftVersions = builtins.mapAttrs (
    version: platforms:
    let
      currentArch = getCurrentArch;
    in
    if builtins.hasAttr currentArch platforms then
      mkSwiftBinary version platforms.${currentArch}
    else
      throw "Architecture ${currentArch} not supported for Swift version ${version}"
  ) (builtins.removeAttrs hashes [ "latest" ]);

in
rec {
  bin = swiftVersions // {
    latest =
      let
        currentArch = getCurrentArch;
        allVersions = builtins.filter (v: v != "nightly") (builtins.attrNames hashes);
        stableVersions = builtins.filter (v: !(builtins.match ".*-.*" v != null)) allVersions;
        sortedVersions = builtins.sort (a: b: builtins.compareVersions a b < 0) stableVersions;
        latestVersion = builtins.elemAt sortedVersions ((builtins.length sortedVersions) - 1);
        latestPlatforms = hashes.${latestVersion};
      in
      if builtins.hasAttr currentArch latestPlatforms then
        mkSwiftBinary latestVersion latestPlatforms.${currentArch}
      else
        throw "Architecture ${currentArch} not supported for latest Swift version ${latestVersion}";
  } // swiftVersions;
}
