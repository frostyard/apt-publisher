#!/usr/bin/env bash
# Publish a producer's .deb files to one or more codenames.
#
# Validates every package against config/producers.tsv and
# config/codenames.tsv before touching state, reconciles aptly's state with
# the bucket, then adds the packages, snapshots each affected codename,
# switches the published suite to the new snapshot as one recoverable
# transaction, and reads the result back from the bucket.
#
# Prints "CODENAME SNAPSHOT" for each published codename on stdout. With
# --report FILE, also writes "codename name version arch" rows for the
# packages it published (the input of apt-canary.sh).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: publish.sh --producer OWNER/REPO --debs DIR [--codenames "trixie forky"]
                  [--label TEXT] [--report FILE] [--dry-run]

  --producer   registered producer (config/producers.tsv)
  --debs       directory holding the release's .deb files
  --codenames  target codenames; default: the producer's configured list
  --label      snapshot name suffix, e.g. updex-v2.0.2; default: producer name
  --report     write the published packages as TSV to FILE
  --dry-run    validate and print the routing, then stop
EOF
	exit 2
}

producer='' debs_dir='' codenames='' label='' report='' dry_run=0
while (($#)); do
	case $1 in
	--producer) producer=${2:?} && shift ;;
	--debs) debs_dir=${2:?} && shift ;;
	--codenames) codenames=${2:?} && shift ;;
	--label) label=${2:?} && shift ;;
	--report) report=${2:?} && shift ;;
	--dry-run) dry_run=1 ;;
	*) usage ;;
	esac
	shift
done
[[ -n $producer && -n $debs_dir ]] || usage
require dpkg-deb

patterns=$(producer_field "$producer" 2) || die "$producer is not a registered producer"
allowed=$(producer_field "$producer" 3)
codenames=${codenames:-${allowed//,/ }}
label=${label:-${producer#*/}}

for codename in $codenames; do
	codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
	in_csv "$codename" "$allowed" || die "$producer may not publish to $codename"
done

shopt -s nullglob
debs=("$debs_dir"/*.deb)
((${#debs[@]})) || die "no .deb files in $debs_dir"

# Route each package to its codenames: a ~debNN/+debNN version goes only to
# the codename for Debian NN; an unmarked version goes to every target.
declare -A files=() expect=()
rows=()
for deb in "${debs[@]}"; do
	name=$(dpkg-deb -f "$deb" Package)
	version=$(dpkg-deb -f "$deb" Version)
	arch=$(dpkg-deb -f "$deb" Architecture)
	matches_globs "$name" "$patterns" || die "$producer may not publish package $name ($deb)"

	targets=$codenames
	if [[ $version =~ [~+]deb([0-9]+) ]]; then
		targets=$(codename_for_major "${BASH_REMATCH[1]}") ||
			die "$deb is built for Debian ${BASH_REMATCH[1]}, which has no configured codename"
		[[ " $codenames " == *" $targets "* ]] ||
			die "$deb is built for $targets, which is not a target of this publication ($codenames)"
	fi
	for codename in $targets; do
		in_csv "$arch" "$(codename_field "$codename" 3)" ||
			die "$deb has architecture $arch, which $codename does not publish"
		files[$codename]+="$deb"$'\n'
		expect[$codename]+="$name=$version "
		rows+=("$codename"$'\t'"$name"$'\t'"$version"$'\t'"$arch")
		log "route $(basename "$deb") -> $codename"
	done
done

if ((dry_run)); then
	log "dry run: nothing published"
	exit 0
fi

aptly_init
for codename in "${!files[@]}"; do
	reconcile_state "$codename"
done

declare -A snapshots=()
commits=()
for codename in $codenames; do
	if [[ -z ${files[$codename]:-} ]]; then
		log "no packages for $codename"
		continue
	fi
	repo=$(ensure_repo "$codename")
	mapfile -t list <<<"${files[$codename]%$'\n'}"
	aptly_ repo add "$repo" "${list[@]}" >&2
	snapshots[$codename]=$(new_snapshot_name "$codename" "$label")
	aptly_ snapshot create "${snapshots[$codename]}" from repo "$repo" >/dev/null
	commits+=("$codename=${snapshots[$codename]}")
done

commit_publications "${commits[@]}"

for codename in "${!snapshots[@]}"; do
	# shellcheck disable=SC2086 # expect holds space-separated NAME=VERSION words
	verify_published "$codename" ${expect[$codename]}
	printf '%s %s\n' "$codename" "${snapshots[$codename]}"
done
if [[ -n $report ]]; then
	printf '%s\n' "${rows[@]}" | sort -u >"$report"
fi
