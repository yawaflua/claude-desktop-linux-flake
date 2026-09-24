#!/usr/bin/env bash
#===============================================================================
# update.sh — bump pkgs/claude-desktop.nix to the newest Claude Desktop release
#
# Nix builds run in a network-less sandbox, so the .nupkg has to be a
# fixed-output derivation with a hash known ahead of time. This script does
# the "on the fly" part outside the sandbox: it resolves the latest release
# from the same Squirrel RELEASES manifest build.sh uses, downloads each
# arch's package, computes its SRI sha256, and rewrites version + both hashes
# in pkgs/claude-desktop.nix. Run it with `nix run .#update`.
#===============================================================================
set -euo pipefail

readonly CLAUDE_RELEASES_BASE='https://downloads.claude.ai/releases/win32'

# Under `nix run` the script lives in the read-only store, so resolve the
# target relative to the invocation directory instead. Walk up from $PWD
# until a pkgs/claude-desktop.nix is found (the flake repo root).
find_nix_file() {
	local dir="$PWD"
	while [[ $dir != / ]]; do
		if [[ -f "$dir/pkgs/claude-desktop.nix" ]]; then
			printf '%s\n' "$dir/pkgs/claude-desktop.nix"
			return 0
		fi
		dir=$(dirname "$dir")
	done
	return 1
}

if ! nix_file=$(find_nix_file); then
	echo 'Cannot find pkgs/claude-desktop.nix. Run this from the flake' \
		'repository (e.g. `nix run .#update` at the repo root).' >&2
	exit 1
fi

# Resolve the newest release for an architecture path (x64 or arm64).
# Echoes "<filename> <sha1>" from the last entry of the RELEASES manifest.
resolve_latest() {
	local arch_path="$1"
	local releases_url="$CLAUDE_RELEASES_BASE/$arch_path/RELEASES"

	local manifest
	if ! manifest=$(wget -qO- "$releases_url"); then
		echo "Failed to fetch RELEASES manifest from $releases_url" >&2
		return 1
	fi

	# Strip BOM and CR, take the last AnthropicClaude-*.nupkg entry.
	local sha1 filename
	read -r sha1 filename _ < <(
		printf '%s' "$manifest" \
			| sed '1s/^\xef\xbb\xbf//' \
			| tr -d '\r' \
			| grep -E '[[:space:]]AnthropicClaude-.*\.nupkg[[:space:]]' \
			| tail -n 1
	)

	if [[ -z $filename || -z $sha1 ]]; then
		echo "Could not parse a release entry from $releases_url" >&2
		return 1
	fi

	printf '%s %s\n' "$filename" "$sha1"
}

# Download <arch_path>/<filename>, verify its SHA-1 against the manifest,
# then echo the SRI sha256 Nix expects.
fetch_sri() {
	local arch_path="$1"
	local filename="$2"
	local expected_sha1="$3"

	local url="$CLAUDE_RELEASES_BASE/$arch_path/$filename"
	local tmp
	tmp=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	echo "  Downloading $url" >&2
	if ! wget -qO "$tmp/pkg.nupkg" "$url"; then
		echo "Failed to download $url" >&2
		return 1
	fi

	local actual_sha1 _
	read -r actual_sha1 _ < <(sha1sum "$tmp/pkg.nupkg")
	if [[ ${actual_sha1,,} != "${expected_sha1,,}" ]]; then
		echo "SHA-1 mismatch for $filename!" >&2
		echo "  Expected: $expected_sha1" >&2
		echo "  Actual:   $actual_sha1" >&2
		return 1
	fi
	echo "  SHA-1 verified: $filename" >&2

	# nix-hash --sri gives the exact sha256-... string used in the flake.
	nix-hash --type sha256 --sri --flat "$tmp/pkg.nupkg"
}

# Extract "1.37937.0" from "AnthropicClaude-1.37937.0-full.nupkg".
version_from_filename() {
	local filename="$1"
	sed -E 's/^AnthropicClaude-(.*)-full\.nupkg$/\1/' <<<"$filename"
}

echo 'Resolving latest Claude Desktop release...'

read -r x64_file x64_sha1 < <(resolve_latest 'x64')
read -r arm64_file arm64_sha1 < <(resolve_latest 'arm64')

x64_version=$(version_from_filename "$x64_file")
arm64_version=$(version_from_filename "$arm64_file")

echo "  x64:   $x64_file"
echo "  arm64: $arm64_file"

if [[ $x64_version != "$arm64_version" ]]; then
	echo "Warning: x64 ($x64_version) and arm64 ($arm64_version)" \
		'versions differ; using x64 as the package version.' >&2
fi
version="$x64_version"

echo "Computing SRI hashes for $version..."
x64_sri=$(fetch_sri 'x64' "$x64_file" "$x64_sha1")
arm64_sri=$(fetch_sri 'arm64' "$arm64_file" "$arm64_sha1")

echo "  version = $version"
echo "  x86_64  = $x64_sri"
echo "  aarch64 = $arm64_sri"

#------------------------------------------------------------------------------
# Rewrite pkgs/claude-desktop.nix in place. The x86_64 block precedes the
# aarch64 block, so a line-scoped awk pass keeps the two hashes distinct.
#------------------------------------------------------------------------------
tmp_nix=$(mktemp)
trap 'rm -f "$tmp_nix"' EXIT

awk \
	-v ver="$version" \
	-v x64="$x64_sri" \
	-v arm64="$arm64_sri" '
	/^  version = "/ {
		sub(/"[^"]*"/, "\"" ver "\"")
		print
		next
	}
	/x86_64-linux = fetchurl/ { arch = "x64" }
	/aarch64-linux = fetchurl/ { arch = "arm64" }
	/hash = "sha256-/ {
		if (arch == "x64") {
			sub(/"sha256-[^"]*"/, "\"" x64 "\"")
			arch = ""
		} else if (arch == "arm64") {
			sub(/"sha256-[^"]*"/, "\"" arm64 "\"")
			arch = ""
		}
		print
		next
	}
	{ print }
' "$nix_file" >"$tmp_nix"

if ! grep -q "version = \"$version\"" "$tmp_nix"; then
	echo 'Failed to update version in claude-desktop.nix' >&2
	exit 1
fi
if ! grep -qF "$x64_sri" "$tmp_nix" || ! grep -qF "$arm64_sri" "$tmp_nix"; then
	echo 'Failed to update one or both hashes in claude-desktop.nix' >&2
	exit 1
fi

cp "$tmp_nix" "$nix_file"
echo "Updated $nix_file to $version"
echo 'Now run: nix build .#claude-desktop'
