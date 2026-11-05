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
# by a person who reads the finding. When the Release says "Acquire-By-Hash:
# yes" (Debian's do), each index is fetched as by-hash/SHA256/<digest>, as apt
# does: a mirror in mid-sync can serve a plain Packages.xz from another sync
# than its Release, but never other bytes under the digest.
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
# The caller runs it on the left of ||, where errexit is off, so every step is
# checked here and dies on failure.
suite_names() {
	local mirror=$1 suite=$2 archs=$3 out=$4 rel=$tmp/Release hash path arch url dirname acquire_by_hash=no indexes=0
	fetch "$mirror/dists/$suite/Release" "$rel" || return $?
	# Refuse a file that is not a Release (an HTML page served with 200, an
	# empty file). Index paths are listed only in the SHA256 section, as
	# "<64 hex> <size> <path>", also for the security archive.
	awk '
		/^SHA256:/ { s = 1; seen = 1; next }
		/^[^ ]/ { s = 0 }
		s {
			if (NF != 3 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ || $2 !~ /^[0-9]+$/) { bad = 1; exit }
			print $1, $3
		}
		END { exit (bad || !seen) }' "$rel" >"$tmp/sha256.list" ||
		die "$mirror/dists/$suite/Release is not a Release file with a valid SHA256 section"
	if awk -F':[[:space:]]*' '$1 == "Acquire-By-Hash" { sub(/\r$/, "", $2); if ($2 == "yes") yes = 1 } END { exit !yes }' "$rel"; then
		acquire_by_hash=yes
	fi
	: >"$out.unsorted"
	# COMPONENT/debian-installer/ holds installer udebs, which no host
	# installs: it does not match the pattern below.
	while read -r hash path; do
		for arch in $archs; do
			[[ $path =~ ^[^/]+/binary-$arch/Packages\.xz$ ]] || continue
			indexes=$((indexes + 1))
			dirname=${path%/*}
			if [[ $acquire_by_hash == yes ]]; then
				url=$mirror/dists/$suite/$dirname/by-hash/SHA256/$hash
			else
				url=$mirror/dists/$suite/$path
			fi
			fetch "$url" "$tmp/Packages.xz" ||
				die "$url is listed in its Release but missing"
			[[ $(sha256sum <"$tmp/Packages.xz" | cut -d' ' -f1) == "$hash" ]] ||
				die "$url does not match the SHA256 in its Release"
			xz -dc "$tmp/Packages.xz" >"$tmp/Packages.txt" || die "$url is not valid xz"
			# Every non-empty stanza names a package; an error page does not.
			awk 'BEGIN { RS = ""; FS = "\n" }
				{ ok = 0; for (i = 1; i <= NF; i++) if ($i ~ /^Package: [^ ]+$/) { print substr($i, 10); ok = 1 }
				  if (!ok) bad = 1 }
				END { exit bad }' "$tmp/Packages.txt" >>"$out.unsorted" ||
				die "$url has a stanza without a Package field"
		done
	done <"$tmp/sha256.list"
	# A Release without any index for our architectures is a broken mirror, not
	# "Debian ships no names".
	((indexes > 0)) || die "$mirror/dists/$suite/Release lists no Packages.xz for $archs"
	LC_ALL=C sort -u "$out.unsorted" >"$out" || die "cannot sort the names of $suite"
}

# Read the codename list with a checked command, so a missing file is fatal.
codenames=$(awk -F'\t' '!/^#/ && NF' "$APT_CODENAMES_FILE") ||
	die "cannot read $APT_CODENAMES_FILE"
[[ -n $codenames ]] || die "$APT_CODENAMES_FILE lists no codename"

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
			# stanzas_tsv dies on a stanza without Filename and SHA256, so an
			# error page is not read as names. Column 4 is the package name,
			# which every stanza must have too.
			stanzas_tsv "$tmp/Packages" >"$tmp/stanzas" ||
				die "$APT_PUBLIC_URL/dists/$codename/main/binary-$arch/Packages is not a Packages index"
			awk -F'\t' '$4 == "" { bad = 1 } END { exit bad }' "$tmp/stanzas" ||
				die "$APT_PUBLIC_URL/dists/$codename/main/binary-$arch/Packages has a stanza without a Package field"
			cut -f4 "$tmp/stanzas" >>"$tmp/frostyard"
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
done <<<"$codenames"

if [[ -s $tmp/findings ]]; then
	LC_ALL=C sort "$tmp/findings"
	exit 1
fi
