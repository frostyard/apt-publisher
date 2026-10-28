#!/usr/bin/env bash
# Catch publication requests that never completed: a dispatch that failed in
# the producer, a cancelled or failed publish run. For each registered
# producer, check that every .deb asset of its latest GitHub release is
# listed by at least one of the producer's codenames at APT_PUBLIC_URL, in the
# producer's own component (main or image).
#
# Report-only: it never publishes, so a withdrawn version is reported, not
# restored. Asset names must follow name_version_arch.deb.
#
# It also checks that the published key, APT_PUBLIC_URL/frostyard.gpg (core
# ADR-0059), exists and matches keys/frostyard.gpg byte for byte.
#
# Exits 1 and prints "MISSING producer tag asset" lines when anything is
# unpublished, and "MISSING key URL" or "MISMATCH key URL" for the key.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require gh curl jq
tmp=$(mktemp -d)
missing=0

# listed_anywhere NAME VERSION ARCH COMPONENT CODENAME... compares versions without
# their epoch, which .deb file names omit, and with ~ read as ., since GitHub
# lists an uploaded bootc_1.0~deb13_amd64.deb as bootc_1.0.deb13_amd64.deb.
listed_anywhere() {
	local name=$1 version=${2//\~/.} arch=$3 component=$4 codename
	shift 4
	for codename in "$@"; do
		awk -F'\t' -v n="$name" -v v="$version" -v a="$arch" \
			'{ ver = $5; sub(/^[0-9]+:/, "", ver); gsub(/~/, ".", ver) } $4 == n && ver == v && $6 == a { found = 1 } END { exit !found }' \
			"$tmp/$codename.$component.tsv" && return 0
	done
	return 1
}

key_url=$APT_PUBLIC_URL/frostyard.gpg
if ! curl -fsSL --retry 3 -o "$tmp/key.gpg" "$key_url"; then
	printf 'MISSING key %s\n' "$key_url"
	missing=1
elif ! cmp -s -- "$tmp/key.gpg" "$APT_KEYRING"; then
	printf 'MISMATCH key %s\n' "$key_url"
	missing=1
fi

declare -A fetched=()
while IFS=$'\t' read -r producer _ codenames _ _ component; do
	IFS=, read -ra targets <<<"$codenames"
	# Each codename's index is read once per component.
	for codename in "${targets[@]}"; do
		[[ -n ${fetched[$codename/$component]:-} ]] && continue
		fetched[$codename/$component]=1
		: >"$tmp/$codename.$component.tsv"
		for arch in $(codename_field "$codename" 3 | tr , ' '); do
			if curl -fsSL --retry 3 -o "$tmp/Packages" "$APT_PUBLIC_URL/dists/$codename/$component/binary-$arch/Packages"; then
				stanzas_tsv "$tmp/Packages" >>"$tmp/$codename.$component.tsv"
			else
				log "warning: $codename/$component/$arch is not published"
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
		if ! listed_anywhere "$name" "$version" "$arch" "$component" "${targets[@]}"; then
			printf 'MISSING %s %s %s\n' "$producer" "$tag" "$asset"
			missing=1
		fi
	done < <(jq -r '.assets[].name | select(endswith(".deb"))' <<<"$release")
	log "audited $producer $tag"
done < <(awk -F'\t' '!/^#/ && NF' "$APT_PRODUCERS_FILE")

rm -rf -- "$tmp"
exit "$missing"
