#!/usr/bin/env bash
# Report every package in Frostyard's main component whose name Debian ships
# for the same codename (core ADR-0059). A package belongs in image when
# Debian ships a binary package of that name in a suite a host of the codename
# can enable: CODENAME, CODENAME-updates, CODENAME-security or
# CODENAME-backports. Main carries only names Debian does not ship; the
# audit catches a name that Debian began to ship later.
#
# Report-only and read-only: no secrets, no aptly, no writes. It never moves
# a package; moving a producer to image is a reviewed registration change.
# It does not look at the image component.
#
# Integrity: Debian's InRelease signature is not verified, since the runner has
# no Debian keyring. HTTPS plus the SHA256 of each index in the Release file is
# the check. That is enough for a report; a decision to move a producer is made
# by a person who reads the finding.
#
# Prints "DEBIAN-NAME codename package suite[,suite...]", sorted, and exits 1
# when there is a finding. A suite that does not exist (HTTP 404) is skipped.
# Any other fetch error, and any hash mismatch, is fatal: a failed fetch must
# never read as "Debian ships no such names".

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require curl xz sha256sum awk sort comm
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# fetch URL FILE returns 0 when saved, 44 when the file does not exist (HTTP 404,
# or a missing file for a file:// URL, which tests use), and dies on any other
# failure. Without -f, curl reports the status in the code it prints.
fetch() {
	local url=$1 file=$2 code rc=0
	code=$(curl -sSL --retry 3 -o "$file" -w '%{http_code}' "$url") || rc=$?
	if [[ $url == file://* ]]; then
		[[ $rc == 0 ]] && return 0
		[[ $rc == 37 ]] && return 44
	else
		[[ $rc == 0 && $code == 200 ]] && return 0
		[[ $rc == 0 && $code == 404 ]] && return 44
	fi
	die "cannot fetch $url (curl exit $rc, HTTP $code)"
}

# suite_names MIRROR SUITE ARCHS OUT writes the sorted package names Debian
# ships in SUITE for ARCHS to OUT, and returns 44 when the suite does not exist.
suite_names() {
	local mirror=$1 suite=$2 archs=$3 out=$4 rel=$tmp/Release hash path arch
	fetch "$mirror/dists/$suite/Release" "$rel" || return $?
	: >"$out.unsorted"
	# Index paths are always COMPONENT/binary-ARCH/Packages.xz, in the SHA256
	# section only, also for the security archive. COMPONENT/debian-installer/
	# holds installer udebs, which no host installs: skip it.
	while read -r hash path; do
		for arch in $archs; do
			[[ $path =~ ^[^/]+/binary-$arch/Packages\.xz$ ]] || continue
			fetch "$mirror/dists/$suite/$path" "$tmp/Packages.xz" ||
				die "$mirror/dists/$suite/$path is listed in its Release but missing"
			[[ $(sha256sum <"$tmp/Packages.xz" | cut -d' ' -f1) == "$hash" ]] ||
				die "$mirror/dists/$suite/$path does not match the SHA256 in its Release"
			xz -dc "$tmp/Packages.xz" | sed -n 's/^Package: //p' >>"$out.unsorted"
		done
	done < <(awk '/^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 } s { print $1, $3 }' "$rel")
	LC_ALL=C sort -u "$out.unsorted" >"$out"
}

while IFS=$'\t' read -r codename _ archs _; do
	archs=${archs//,/ }
	: >"$tmp/frostyard"
	published=0
	# Frostyard's own index: absent is a warning; any other failure is fatal,
	# so a failed read never reads as "no names in main".
	for arch in $archs; do
		rc=0
		fetch "$APT_PUBLIC_URL/dists/$codename/main/binary-$arch/Packages" "$tmp/Packages" || rc=$?
		if [[ $rc == 0 ]]; then
			published=1
			sed -n 's/^Package: //p' "$tmp/Packages" >>"$tmp/frostyard"
		else
			log "warning: $codename/main/$arch is not published"
		fi
	done
	if [[ $published == 0 ]]; then
		log "warning: $codename is not published, skipped"
		continue
	fi
	LC_ALL=C sort -u -o "$tmp/frostyard" "$tmp/frostyard"

	: >"$tmp/hits"
	for suite in "$codename" "$codename-updates" "$codename-security" "$codename-backports"; do
		mirror=$APT_DEBIAN_MIRROR
		[[ $suite == *-security ]] && mirror=$APT_DEBIAN_SECURITY_MIRROR
		rc=0
		suite_names "$mirror" "$suite" "$archs" "$tmp/debian" || rc=$?
		if [[ $rc == 44 ]]; then
			log "$suite does not exist at $mirror, skipped"
			continue
		fi
		[[ $rc == 0 ]] || exit "$rc"
		LC_ALL=C comm -12 "$tmp/frostyard" "$tmp/debian" | sed "s/\$/ $suite/" >>"$tmp/hits"
		log "audited $codename against $suite"
	done
	# One line per package; its suites in sorted order.
	LC_ALL=C sort "$tmp/hits" | awk -v c="$codename" '
		$1 != p { if (p != "") print "DEBIAN-NAME", c, p, s; p = $1; s = $2; next }
		{ s = s "," $2 }
		END { if (p != "") print "DEBIAN-NAME", c, p, s }' >>"$tmp/findings"
done < <(awk -F'\t' '!/^#/ && NF' "$APT_CODENAMES_FILE")

if [[ -s $tmp/findings ]]; then
	LC_ALL=C sort "$tmp/findings"
	exit 1
fi
