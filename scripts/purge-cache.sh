#!/usr/bin/env bash
# Purge the mutable index files of the given codenames from the Cloudflare
# cache. by-hash files are content-addressed and never need purging.
#
# --print lists the URLs without calling the API.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

print=0
if [[ ${1:-} == --print ]]; then
	print=1
	shift
fi
(($#)) || {
	echo "usage: purge-cache.sh [--print] CODENAME..." >&2
	exit 2
}

urls=()
for codename in "$@"; do
	archs=$(codename_field "$codename" 3) || die "unknown codename $codename"
	base="$APT_PUBLIC_URL/dists/$codename"
	urls+=("$base/InRelease" "$base/Release" "$base/Release.gpg")
	for arch in ${archs//,/ }; do
		for f in Packages Packages.gz Packages.bz2 Release; do
			urls+=("$base/$APT_COMPONENT/binary-$arch/$f")
		done
	done
done

if ((print)); then
	printf '%s\n' "${urls[@]}"
	exit 0
fi

require curl jq
: "${CLOUDFLARE_ZONE:?CLOUDFLARE_ZONE is required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
# The purge-by-URL API accepts at most 30 files per request.
for ((i = 0; i < ${#urls[@]}; i += 30)); do
	jq -n '{files: $ARGS.positional}' --args "${urls[@]:i:30}" |
		curl -fsS --retry 3 -X POST \
			-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
			-H 'Content-Type: application/json' \
			--data @- \
			"https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE/purge_cache" |
		jq -e '.success' >/dev/null || die "Cloudflare purge failed"
done
log "purged ${#urls[@]} URLs"
