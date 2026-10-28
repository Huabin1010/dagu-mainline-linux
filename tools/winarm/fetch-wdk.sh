#!/usr/bin/env bash
# Fetch and unpack the Windows WDK/SDK headers+libs that
# tools/winarm/build-himax-sys.sh needs, from NuGet (no Windows install).
#
#   tools/winarm/fetch-wdk.sh [DEST]      # default DEST=winarm/wdk (gitignored)
#
# The NuGet trees use mixed case (c/Include/..., km/Wdm.h ...) and the headers
# #include each other with whatever case the author typed, which only works on
# a case-insensitive file system. On Linux we lowercase every path, and the
# file names inside #include directives, so every lookup is lowercase.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-$ROOT/winarm/wdk}"
VER=10.0.26100.4204
PKGS="microsoft.windows.wdk.arm64 microsoft.windows.sdk.cpp microsoft.windows.sdk.cpp.arm64"
mkdir -p "$DEST/ex"
for p in $PKGS; do
	nupkg="$DEST/$p.$VER.nupkg"
	if [ ! -s "$nupkg" ]; then
		echo "== download $p $VER"
		curl -fL --retry 3 -o "$nupkg.part" "https://www.nuget.org/api/v2/package/$p/$VER"
		mv "$nupkg.part" "$nupkg"
	fi
	out="$DEST/ex/$p"
	rm -rf "$out"
	mkdir -p "$out"
	echo "== unpack $p"
	unzip -q "$nupkg" -d "$out"
	# Lowercase names deepest-first so parents are renamed after children.
	find "$out" -depth -mindepth 1 | while IFS= read -r f; do
		b="$(basename "$f")"; l="$(printf '%s' "$b" | tr 'A-Z' 'a-z')"
		[ "$b" = "$l" ] || mv -- "$f" "$(dirname "$f")/$l"
	done
	# Lowercase the path inside #include <...> / "..." directives.
	find "$out" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inl' \) -print0 |
		xargs -0 -r perl -pi -e 's{^(\s*#\s*include\s*)([<"])([^>"]+)([>"])}{$1.$2.lc($3).$4}e'
done
echo "WDK ready under $DEST/ex"
