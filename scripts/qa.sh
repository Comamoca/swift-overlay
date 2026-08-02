#!/usr/bin/env bash
# Host-run QA for the Swift toolchain package.
# NOTE: bubblewrap cannot create namespaces inside the nix build sandbox,
# so this is a host-run script — intentionally not a flake check.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FLAKE_REF="${1:-.}"
RESULT=result-qa
step() { printf '\n== %s ==\n' "$*"; }
fail() { echo "QA FAIL: $*" >&2; exit 1; }
warn() { echo "QA WARN: $*" >&2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$RESULT"' EXIT

step "build $FLAKE_REF"
nix build "$FLAKE_REF" -o "$RESULT"
SW="$PWD/$RESULT/bin"

step "happy: swift --version"
"$SW/swift" --version | tee "$tmp/version.txt"
grep -q "Swift version 6.3.3" "$tmp/version.txt" || fail "unexpected swift version"

step "happy: swiftc compiles, links and runs a Foundation program"
cat > "$tmp/hello.swift" <<'EOF'
import Foundation
let data = try JSONEncoder().encode(["n": 42])
print("hello-swift-\(data.count)-\(6 * 7)")
EOF
"$SW/swiftc" -o "$tmp/hello" "$tmp/hello.swift" || fail "swiftc failed"
got="$("$tmp/hello")"
[ "$got" = "hello-swift-8-42" ] || fail "unexpected output: $got"

step "edge: SwiftPM fixture — build, run, test (Foundation, FoundationNetworking, XCTest)"
cp -r tests/fixture "$tmp/fixture"
(
  cd "$tmp/fixture"
  "$SW/swift" build || fail "swift build"
  run_out="$("$SW/swift" run fixture-cli)" || fail "swift run"
  echo "$run_out" | grep -q "fixture-ok" || fail "swift run output: $run_out"
  "$SW/swift" test || fail "swift test"
)

step "edge: interpreter mode (swift -)"
echo 'print("interp-ok")' | "$SW/swift" - | grep -q interp-ok || warn "interpreter mode degraded"

step "diag: shared-library resolution inside the FHS env"
UNW="$(nix eval --raw "$FLAKE_REF#default.passthru.unwrapped.outPath")" \
  || fail "passthru.unwrapped missing (expected pre-FHS refactor)"
FHS="$(nix eval --raw "$FLAKE_REF#default.passthru.fhs.outPath")/bin/swift-fhs"
[ -x "$FHS" ] || fail "fhs wrapper missing at $FHS"
miss=0
# Only check top-level entrypoint binaries. Toolchain-internal .so files under
# /usr/lib/swift/ resolve each other at runtime via $ORIGIN RPATHs (confirmed
# by swift build/test passing), but ldd's flat transitive output often reports
# them as "not found" from a different FHS symlink path.
while IFS= read -r -d '' f; do
  rel="${f#"$UNW"/}"
  [ "${rel#bin/}" != "$rel" ] || continue
  head -c4 "$f" | grep -q $'\x7fELF' || continue
  out="$("$FHS" ldd "$f" 2>&1)" || true
  if printf '%s' "$out" | grep -q "not found"; then
    printf '  %s\n' "$f"
    printf '%s\n' "$out" | grep "not found" | sed 's/^/    /'
    # Advisory-only sonames (lldb/REPL): UBI9 wants libedit.so.2 and
    # libpython3.9.so.1.0; nixpkgs ships libedit.so.0 and python 3.14.
    if printf '%s' "$out" | grep "not found" | grep -vqE 'libedit\.so\.2|libpython3\.[0-9]+\.so'; then
      miss=1
    fi
  fi
done < <(find "$UNW/bin" -type f -print0 2>/dev/null)
[ "$miss" = 0 ] || fail "unresolved shared libraries inside the FHS env"

step "regression: evaluation matrix (non-native systems)"
for sys in aarch64-linux aarch64-darwin; do
  nix eval --raw "$FLAKE_REF#packages.$sys.default.drvPath" > /dev/null || fail "eval $sys"
  echo "  $sys OK"
done

step "regression: flake interface and overlay consumer"
nix flake show "$FLAKE_REF" > /dev/null || fail "nix flake show"
name="$(nix eval --raw --impure --expr '
  let f = builtins.getFlake (toString ./.);
      pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; overlays = [ f.overlays.default ]; };
  in pkgs.swift.bin.latest.name')"
[ "$name" = "swift-6.3.3" ] || fail "overlay consumer name: $name"

step "regression: no Ubuntu/autoPatchelf remnants"
! grep -qi ubuntu swift_hashes.json || fail "ubuntu URL still in swift_hashes.json"
# Only match non-comment lines; the FHS rewrite deliberately comments on the
# absence of these old hacks, which would otherwise trigger a false positive.
! grep -nE '^[ \t]*[^#]*\b(autoPatchelf|patchelf --|linkSysroot)\b' swift.nix || fail "autoPatchelf-era hacks still in swift.nix"
url="$(nix eval --raw "$FLAKE_REF#default.passthru.unwrapped.src.url")"
case "$url" in *ubi9*) ;; *) fail "src.url is not UBI9: $url" ;; esac

step "regression: README is in sync with generator"
if command -v uv >/dev/null; then
  cp README.md "$tmp/README.before"
  uv run python scripts/generate_readme.py > /dev/null
  diff -q "$tmp/README.before" README.md > /dev/null || { cp "$tmp/README.before" README.md; fail "README.md out of sync"; }
fi

step "advisory: REPL"
if printf 'print("repl-ok")\n:quit\n' | timeout 120 "$SW/swift" repl 2>&1 | grep -q repl-ok; then
  echo "  REPL OK"
else
  warn "REPL degraded (lldb wants UBI9 sonames libedit.so.2 / libpython3.9.so.1.0 — documented limitation)"
fi

step "QA PASSED"
