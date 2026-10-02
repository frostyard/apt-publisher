#!/usr/bin/env bash
# Download a producer's release .deb files and, for attested producers,
# verify each file's build provenance against the producer's tag.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[[ $# == 3 ]] || {
	echo "usage: fetch-release.sh OWNER/REPO TAG OUTDIR" >&2
	exit 2
}
producer=$1 tag=$2 out=$3
require gh
attested=$(producer_field "$producer" 4) || die "$producer is not a registered producer"

mkdir -p "$out"
gh release download "$tag" --repo "$producer" --pattern '*.deb' --dir "$out"

shopt -s nullglob
debs=("$out"/*.deb)
((${#debs[@]})) || die "$producer $tag has no .deb assets"

if [[ $attested == yes ]]; then
	for deb in "${debs[@]}"; do
		gh attestation verify "$deb" --repo "$producer" \
			--source-ref "refs/tags/$tag" --deny-self-hosted-runners >&2 ||
			die "$(basename "$deb") has no valid provenance from $producer at $tag"
	done
else
	log "warning: $producer is not attested; trusting release assets as downloaded"
fi
