#!/usr/bin/env bash
# Install-path canary: point a sandboxed apt (no root, no system state) at
# APT_PUBLIC_URL, run apt-get update, and download each package with
# apt-get download, so apt itself checks the signature, the indexes and the
# package hashes through the public delivery path (CDN included).
#
#   apt-canary.sh CODENAME ARCH NAME=VERSION...
#   apt-canary.sh --report FILE      rows of "codename name version arch"
#
# arch:all packages are fetched with an amd64 apt configuration.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require apt-get

# canary CODENAME ARCH NAME=VERSION...
canary() {
	local codename=$1 arch=$2
	shift 2
	local d opts spec
	d=$(mktemp -d)
	mkdir -p "$d/etc/sources.list.d" "$d/etc/apt.conf.d" "$d/etc/preferences.d" \
		"$d/state/lists/partial" "$d/cache/archives/partial" "$d/download"
	: >"$d/state/status"
	printf 'Types: deb\nURIs: %s/\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
		"$APT_PUBLIC_URL" "$codename" "$APT_COMPONENT" "$APT_KEYRING" >"$d/etc/sources.list.d/canary.sources"
	opts=(-o "Dir::Etc=$d/etc" -o Dir::Etc::sourcelist=/dev/null
		-o "Dir::Etc::sourceparts=$d/etc/sources.list.d" -o "Dir::State=$d/state"
		-o "Dir::State::status=$d/state/status" -o "Dir::Cache=$d/cache"
		-o Debug::NoLocking=1 -o "APT::Architecture=$arch" -o "APT::Architectures::=$arch"
		-o "APT::Sandbox::User=$(id -un)")
	if ! apt-get "${opts[@]}" -q update >"$d/update.log" 2>&1 || grep -q '^[WE]:' "$d/update.log"; then
		die "apt-get update of $codename/$arch failed: $(cat "$d/update.log")"
	fi
	for spec in "$@"; do
		(cd "$d/download" && apt-get "${opts[@]}" -q download "$spec") >"$d/download.log" 2>&1 ||
			die "apt-get download $spec from $codename/$arch failed: $(cat "$d/download.log")"
	done
	rm -rf -- "$d"
	log "canary $codename/$arch: $*"
}

if [[ ${1:-} == --report ]]; then
	[[ -f ${2:-} ]] || die "usage: apt-canary.sh --report FILE"
	# One apt configuration per codename and architecture.
	while read -r codename arch; do
		mapfile -t specs < <(awk -F'\t' -v c="$codename" -v a="$arch" \
			'$1 == c && ($4 == a || ($4 == "all" && a == "amd64")) { print $2 "=" $3 }' "$2" | sort -u)
		canary "$codename" "$arch" "${specs[@]}"
	done < <(awk -F'\t' '{ print $1, ($4 == "all" ? "amd64" : $4) }' "$2" | sort -u)
	exit 0
fi

(($# >= 3)) || die "usage: apt-canary.sh CODENAME ARCH NAME=VERSION... | --report FILE"
canary "$@"
