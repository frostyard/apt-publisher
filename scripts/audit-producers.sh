#!/usr/bin/env bash
# Catch publication requests that never completed: a dispatch that failed in
# the producer, a cancelled or failed publish run. For each registered
# producer, check that every .deb asset of its latest GitHub release is
# listed by at least one of the producer's codenames at APT_PUBLIC_URL.
#
# Report-only: it never publishes, so a withdrawn version is reported, not
# restored. Asset names must follow name_version_arch.deb.
#
# Exits 1 and prints "MISSING producer tag asset" lines when anything is
# unpublished.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require gh curl jq
tmp=$(mktemp -d)
missing=0

# listed_anywhere NAME VERSION ARCH CODENAME... compares versions without
# their epoch, which .deb file names omit.
listed_anywhere() {
	local name=$1 version=$2 arch=$3 codename
	shift 3
	for codename in "$@"; do
		awk -F'\t' -v n="$name" -v v="$version" -v a="$arch" \
			'{ ver = $5; sub(/^[0-9]+:/, "", ver) } $4 == n && ver == v && $6 == a { found = 1 } END { exit !found }' \
			"$tmp/$codename.tsv" && return 0
	done
	return 1
}

declare -A fetched=()
while IFS=$'\t' read -r producer _ codenames _ _; do
	IFS=, read -ra targets <<<"$codenames"
	for codename in "${targets[@]}"; do
		[[ -n ${fetched[$codename]:-} ]] && continue
		fetched[$codename]=1
		: >"$tmp/$codename.tsv"
		for arch in $(codename_field "$codename" 3 | tr , ' '); do
			if curl -fsSL --retry 3 -o "$tmp/Packages" "$APT_PUBLIC_URL/dists/$codename/$APT_COMPONENT/binary-$arch/Packages"; then
				stanzas_tsv "$tmp/Packages" >>"$tmp/$codename.tsv"
			else
				log "warning: $codename/$arch is not published"
			fi
		done
	done

	release=$(gh release view --repo "$producer" --json tagName,assets) || {
		log "MISSING $producer: cannot read its latest release"
		missing=1
		continue
	}
	tag=$(jq -r .tagName <<<"$release")
	while read -r asset; do
		IFS=_ read -r name version arch <<<"${asset%.deb}"
		version=${version//%3a/:}
		if ! listed_anywhere "$name" "$version" "$arch" "${targets[@]}"; then
			printf 'MISSING %s %s %s\n' "$producer" "$tag" "$asset"
			missing=1
		fi
	done < <(jq -r '.assets[].name | select(endswith(".deb"))' <<<"$release")
	log "audited $producer $tag"
done < <(awk -F'\t' '!/^#/ && NF' "$APT_PRODUCERS_FILE")

rm -rf -- "$tmp"
exit "$missing"
