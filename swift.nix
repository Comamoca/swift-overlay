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
          pkgs.libxml2.out
          pkgs.sqlite
          pkgs.ncurses
          pkgs.libedit
          pkgs.libuuid
          pkgs.python312
        ] else [ ];

      autoPatchelfIgnoreMissing = true;

      preFixupPhases = if pkgs.stdenv.isLinux then [ "linkSysroot" ] else [ ];

      linkSysroot = ''
        GLIBC_LIB="${pkgs.glibc.out}/lib"
        GCC_CRT="${pkgs.stdenv.cc.cc}/lib/gcc/*/*"
        GCC_LIB="${pkgs.stdenv.cc.cc.lib}/lib"

        cp -L "$GLIBC_LIB"/crt1.o $out/lib/
        cp -L "$GLIBC_LIB"/crti.o $out/lib/
        cp -L "$GLIBC_LIB"/crtn.o $out/lib/
        ln -sf crt1.o $out/lib/Scrt1.o

        for d in $GCC_CRT; do
          cp -L "$d"/crtbegin*.o $out/lib/ 2>/dev/null || true
          cp -L "$d"/crtend*.o $out/lib/ 2>/dev/null || true
          cp -L "$d"/libgcc*.a $out/lib/ 2>/dev/null || true
        done

        cp -L "$GCC_LIB"/libgcc* $out/lib/ 2>/dev/null || true
        for lib in libc libm libdl libpthread librt libutil libcrypt libresolv; do
          cp -L "$GLIBC_LIB"/$lib.* "$out/lib/" 2>/dev/null || true
        done
      '';

      postFixup =
        if pkgs.stdenv.isLinux then ''
          ln -sf lld $out/bin/ld 2>/dev/null || true

          # Create sysroot with glibc headers for CDispatch <sys/param.h> resolution
          GLIBC_DEV="${pkgs.glibc.dev}/include"
          mkdir -p $out/usr/include
          cp -rsf "$GLIBC_DEV/." "$out/usr/include/" 2>/dev/null || true

          # Symlink glibc headers into SwiftGlibc module map directory
          SWIFT_ARCH_DIR="$out/lib/swift/linux/x86_64"
          for hdr in assert.h ctype.h errno.h fcntl.h fenv.h float.h fnmatch.h \
                     ftw.h glob.h grp.h iconv.h langinfo.h libgen.h locale.h \
                     monetary.h nl_types.h poll.h pwd.h regex.h sched.h search.h \
                     semaphore.h signal.h spawn.h stdio.h stdlib.h string.h \
                     strings.h sysexits.h syslog.h tar.h termios.h time.h \
                     unistd.h utime.h utmpx.h wordexp.h features.h complex.h \
                     inttypes.h iso646.h limits.h stdarg.h stdbool.h stddef.h \
                     stdint.h tgmath.h ulimit.h; do
            [ -f "$GLIBC_DEV/$hdr" ] && ln -sf "$GLIBC_DEV/$hdr" "$SWIFT_ARCH_DIR/$hdr" 2>/dev/null || true
          done
          for sdir in sys net netinet arpa bits; do
            [ -d "$GLIBC_DEV/$sdir" ] && ln -sfn "$GLIBC_DEV/$sdir" "$SWIFT_ARCH_DIR/$sdir" 2>/dev/null || true
          done

          # libc.so: replace absolute Nix store paths with simple INPUT for LLD --sysroot compat
          if [ -f "$out/lib/libc.so" ]; then
            echo "INPUT(libc.so.6)" > "$out/lib/libc.so"
          fi

          wrapProgram $out/bin/swiftc \
            --prefix PATH : $out/bin \
            --add-flags "-Xcc" --add-flags "--sysroot=$out" \
            --add-flags "-Xcc" --add-flags "-fmodule-map-file=$out/lib/swift/linux/x86_64/glibc.modulemap" \
            --add-flags "-Xlinker" --add-flags "-L$out/lib"

          wrapProgram $out/bin/swift \
            --prefix PATH : $out/bin \
            --set SWIFT_CC "$out/bin/clang" \
            --set CC "$out/bin/clang" \
            --set CXX "$out/bin/clang++"

          # Fix: -modulewrap flag (swift-driver doesn't support it)
          rm -f $out/bin/.swiftc-wrapped $out/bin/.swift-wrapped
          for driver_link in .swiftc-wrapped .swift-wrapped; do
            cat > $out/bin/$driver_link << DRVEOF
#!/bin/bash
case "\$0" in *.swiftc-wrapped) mode="swiftc" ;; *) mode="swift" ;; esac
ARGS=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -Xfrontend) ARGS+=("\$1"); shift ;;
    -modulewrap)
      REMAINING=(); shift
      while [ \$# -gt 0 ]; do REMAINING+=("\$1"); shift; done
      exec $out/bin/swift-frontend -modulewrap "\''${REMAINING[@]}";;
    *) ARGS+=("\$1"); shift ;;
  esac
done
exec -a "\$mode" $out/bin/swift-driver "\''${ARGS[@]}"
DRVEOF
            chmod +x $out/bin/$driver_link
          done

          # Create compat stub for ELF version symbol shims
          cat > $TMPDIR/compat_stub.c << 'COMPATEOF'
int compat_stub = 0;
COMPATEOF

          # SONAME compat: translate old SONAMEs to current Nixpkgs SONAMEs
          for elf in $(find $out -type f -executable 2>/dev/null; find $out/lib -name "*.so*" -type f 2>/dev/null); do
            patchelf --replace-needed libxml2.so.2 libxml2.so.16 "$elf" 2>/dev/null || true
            patchelf --replace-needed libedit.so.2 libedit.so.0 "$elf" 2>/dev/null || true
          done

          # libxml2: "no version information available" warning is cosmetic.
          # To fully fix it, libxml2 would need to be rebuilt from source
          # with a version script (too heavy for this overlay).

          # Compat: ncurses version symbols for lldb
          cat > $TMPDIR/ncurses_version.ver << NCRVER
NCURSES6_5.0.19991023 { global: *; };
NCURSES6_5.6.20061217 { global: *; };
NCRVER
          NCURSES_LIB="${pkgs.ncurses}/lib"
          ${pkgs.stdenv.cc.targetPrefix}gcc -shared -fPIC -o $out/lib/libncurses_compat.so \
            $TMPDIR/compat_stub.c \
            -Wl,--version-script=$TMPDIR/ncurses_version.ver \
            -L$NCURSES_LIB -lncurses -lpanel 2>/dev/null || true
          for elf in $(find $out -type f -executable 2>/dev/null; find $out/lib -name "*.so*" -type f 2>/dev/null); do
            patchelf --replace-needed libncurses.so.6 libncurses_compat.so "$elf" 2>/dev/null || true
            patchelf --replace-needed libpanel.so.6 libncurses_compat.so "$elf" 2>/dev/null || true
          done

          # Add RPATH so compat libs are found
          for elf in $(find $out -type f -executable 2>/dev/null; find $out/lib -name "*.so*" -type f 2>/dev/null); do
            patchelf --add-rpath "$out/lib" "$elf" 2>/dev/null || true
          done
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

      dontStrip = true;

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
