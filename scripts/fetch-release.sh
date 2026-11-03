#!/usr/bin/env bash
# Download a producer's release .deb files and, for an attested producer,
# verify each file's build provenance against the producer's policy: the
# signing workflow (--signer-workflow) and the ref it ran on (--source-ref),
# see ADR-0004.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[[ $# == 3 ]] || {
	echo "usage: fetch-release.sh OWNER/REPO TAG OUTDIR" >&2
	exit 2
}
producer=$1 tag=$2 out=$3
require gh
attested=$(producer_field "$producer" 4) || die "$producer is not a registered producer"

# Column 4 is no, or WORKFLOW@refs/tags/PATTERN, or WORKFLOW@refs/heads/BRANCH.
provenance_re='^(no|[A-Za-z0-9_.-]+\.ya?ml@refs/(tags/[A-Za-z0-9_.*?-]+|heads/[A-Za-z0-9_./-]+))$'
[[ $attested =~ $provenance_re ]] ||
	die "$producer: attested is '$attested', which is invalid; it must be no or WORKFLOW@refs/tags/PATTERN or WORKFLOW@refs/heads/BRANCH (for example release.yml@refs/tags/v*)"

workflow='' source_ref=''
if [[ $attested != no ]]; then
	workflow=${attested%%@*}
	source_ref=${attested#*@}
	if [[ $source_ref == refs/tags/* ]]; then
		# The release tag must match the pattern, and the provenance must
		# come from that tag.
		pattern=${source_ref#refs/tags/}
		# shellcheck disable=SC2053 # the right-hand side is a glob on purpose
		[[ $tag == $pattern ]] ||
			die "$producer releases only tags that match $pattern; $tag does not"
		source_ref="refs/tags/$tag"
	fi
fi

mkdir -p "$out"
gh release download "$tag" --repo "$producer" --pattern '*.deb' --dir "$out"

shopt -s nullglob
debs=("$out"/*.deb)
((${#debs[@]})) || die "$producer $tag has no .deb assets"

if [[ -n $workflow ]]; then
	for deb in "${debs[@]}"; do
		gh attestation verify "$deb" --repo "$producer" \
			--signer-workflow "$producer/.github/workflows/$workflow" \
			--source-ref "$source_ref" --deny-self-hosted-runners >&2 ||
			die "$(basename "$deb") has no valid provenance from $workflow at $source_ref in $producer"
	done
	log "verified the provenance of ${#debs[@]} files: $producer/.github/workflows/$workflow at $source_ref"
else
	log "warning: $producer is not attested; trusting release assets as downloaded"
fi
