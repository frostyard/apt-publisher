#!/usr/bin/env bash
# Publish a producer's .deb files to one or more codenames.
#
# Validates every package against config/producers.tsv and
# config/codenames.tsv before touching state, reconciles aptly's state with
# the bucket, then adds the packages, snapshots each affected codename,
# switches the published suite to the new snapshot as one recoverable
# transaction, and reads the result back from the bucket.
#
# A producer's packages go to the one component it is registered for (main
# or image, core ADR-0059). A codename that aptly does not publish yet is
# first published with every configured component; the others start empty.
# A published codename that lacks a configured component gets it, empty, in
# the next run, also when the request does not target that codename: aptly
# cannot add a component by switching (publish_snapshot).
#
# Prints "CODENAME SNAPSHOT" for each published codename on stdout, the
# snapshot being the producer's component, or the added component for a
# codename the request does not target (several, space-separated, when a run
# adds more than one). With --report FILE, also writes
# "codename name version arch component" rows for the packages it published
# (the input of apt-canary.sh). With --pruned FILE, writes the rows of the
# versions retention withdrew in this run, or an empty file when it withdrew
# none.
#
# Retention (core ADR-0067): column 7 of config/producers.tsv, keep, holds
# how many of the newest versions of each of the producer's packages stay.
# The publication that adds newer ones withdraws the rest from the index in
# the same publication: they leave the working repository before the
# snapshot, so no pool file is deleted. A publication whose own packages
# would be withdrawn at once is refused before any state changes.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: publish.sh --producer OWNER/REPO --debs DIR [--codenames "trixie forky"]
                  [--label TEXT] [--report FILE] [--pruned FILE] [--dry-run]

  --producer   registered producer (config/producers.tsv)
  --debs       directory holding the release's .deb files
  --codenames  target codenames; default: the producer's configured list
  --label      snapshot name suffix, e.g. updex-v2.0.2; default: producer name
  --report     write the published packages as TSV to FILE
  --pruned     write the withdrawn packages as TSV to FILE (empty if none)
  --dry-run    validate and print the routing, then stop
EOF
	exit 2
}

producer='' debs_dir='' codenames='' label='' report='' pruned_file='' dry_run=0
while (($#)); do
	case $1 in
	--producer) producer=${2:?} && shift ;;
	--debs) debs_dir=${2:?} && shift ;;
	--codenames) codenames=${2:?} && shift ;;
	--label) label=${2:?} && shift ;;
	--report) report=${2:?} && shift ;;
	--pruned) pruned_file=${2:?} && shift ;;
	--dry-run) dry_run=1 ;;
	*) usage ;;
	esac
	shift
done
[[ -n $producer && -n $debs_dir ]] || usage
require dpkg dpkg-deb

patterns=$(producer_field "$producer" 2) || die "$producer is not a registered producer"
allowed=$(producer_field "$producer" 3)
component=$(producer_field "$producer" 6)
# Column 7 is empty for a six-column row: no limit.
keep=$(producer_field "$producer" 7)
if [[ -n $keep && $keep != - ]]; then
	[[ $keep =~ ^[1-9][0-9]*$ ]] ||
		die "producer $producer has keep '$keep' in config/producers.tsv: give a positive integer or - for no limit"
fi
codenames=${codenames:-${allowed//,/ }}
label=${label:-${producer#*/}}

for codename in $codenames; do
	codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
	in_csv "$codename" "$allowed" || die "$producer may not publish to $codename"
	in_csv "$component" "$(codename_components "$codename")" ||
		die "$codename does not publish component $component ($producer is registered for it)"
done

shopt -s nullglob
debs=("$debs_dir"/*.deb)
((${#debs[@]})) || die "no .deb files in $debs_dir"

# Route each package to its codenames: a ~debNN/+debNN version goes only to
# the codename for Debian NN; an unmarked version goes to every target.
declare -A files=() expect=() names=() releases=()
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
		expect[$codename]+="$component/$name=$version "
		names[$codename]+="$name "
		releases[$codename]+="$name $version $arch"$'\n'
		rows+=("$codename"$'\t'"$name"$'\t'"$version"$'\t'"$arch"$'\t'"$component")
		log "route $(basename "$deb") -> $codename/$component"
	done
done

if ((dry_run)); then
	if [[ -n $keep && $keep != - ]]; then
		log "retention: keep the newest $keep versions of each package of $producer in $component"
	fi
	log "dry run: nothing published"
	exit 0
fi

aptly_init
for codename in "${!files[@]}"; do
	reconcile_state "$codename"
done

# A codename this run publishes no package to (not targeted, or targeted with
# no package routed to it), but that aptly publishes without a configured
# component, gets that component in this run too: reconcile it before any
# repository change.
extra_codenames=()
declare -A adding=()
while IFS= read -r codename; do
	[[ -n $codename ]] || continue
	[[ -z ${files[$codename]:-} ]] || continue
	published_set=$(published_components "$codename")
	[[ -n $published_set ]] || continue
	[[ $published_set != "$(component_set "$(codename_components "$codename")")" ]] || continue
	# The components to add. reconcile_state can already complete an
	# interrupted addition; the codename is still verified and printed below,
	# so the workflow purges its CDN cache.
	adding[$codename]=''
	for c in $(codename_components "$codename" | tr , ' '); do
		in_csv "$c" "$published_set" || adding[$codename]+="$c "
	done
	reconcile_state "$codename"
	extra_codenames+=("$codename")
done < <(awk -F'\t' '!/^#/ && NF { print $1 }' "$APT_CODENAMES_FILE")

declare -A snapshots=() pruned_specs=()
commits=()
pruned_rows=()
for codename in $codenames; do
	if [[ -z ${files[$codename]:-} ]]; then
		log "no packages for $codename"
		continue
	fi
	mapfile -t unique_names < <(printf '%s\n' "${names[$codename]% }" | tr ' ' '\n' | sort -u)
	one_component_rule "$codename" "$component" "${unique_names[@]}"
	repo=$(ensure_repo "$codename" "$component")
	mapfile -t list <<<"${files[$codename]%$'\n'}"
	aptly_ repo add "$repo" "${list[@]}" >&2
	if [[ -n $keep && $keep != - ]]; then
		# Retention (core ADR-0067): older versions leave the working
		# repository before the snapshot, so this publication withdraws
		# them. Nothing was saved yet, so a refusal changes no state.
		pruned_pairs=()
		prune=$(retention_rows "$repo" "$keep" "$patterns") ||
			die "cannot apply retention to $repo"
		while read -r name version arch; do
			[[ -n $name ]] || continue
			if grep -qxF -- "$name $version $arch" <<<"${releases[$codename]:-}"; then
				die "$name $version $arch is older than the newest $keep published versions; retention would withdraw it at once"
			fi
			log "prune $codename $component $name $version $arch"
			aptly_ repo remove "$repo" "$name (= $version) {$arch}" >&2
			pruned_pairs+=("$name=$version")
			pruned_rows+=("$codename"$'\t'"$name"$'\t'"$version"$'\t'"$arch"$'\t'"$component")
		done <<<"$prune"
		if ((${#pruned_pairs[@]})); then
			# Read back from the repository: a version that another
			# architecture keeps stays listed.
			remaining=$(repo_set "$repo")
			for pair in "${pruned_pairs[@]}"; do
				if awk -v n="${pair%%=*}" -v v="${pair#*=}" \
					'$1 == n && $2 == v { found = 1 } END { exit !found }' <<<"$remaining"; then
					continue
				fi
				pruned_specs[$codename]+="!$component/$pair "
			done
		fi
	fi
	snapshots[$codename]=$(new_snapshot_name "$codename" "$component" "$label")
	aptly_ snapshot create "${snapshots[$codename]}" from repo "$repo" >/dev/null
	commits+=("$codename/$component=${snapshots[$codename]}")
	others=$(missing_component_snapshots "$codename" "$label" "$component")
	if [[ -n $others ]]; then
		mapfile -t others_list <<<"$others"
		commits+=("${others_list[@]}")
	fi
done

for codename in "${extra_codenames[@]}"; do
	others=$(missing_component_snapshots "$codename" "$label")
	[[ -n $others ]] || continue
	mapfile -t others_list <<<"$others"
	commits+=("${others_list[@]}")
done

commit_publications "${commits[@]}"

# Each extra codename is printed with the snapshots of its added components,
# whether this run's commit or its reconciliation published them.
for codename in "${extra_codenames[@]}"; do
	added=()
	for c in ${adding[$codename]}; do
		snapshot=$(published_snapshot "$codename" "$c")
		[[ -n $snapshot ]] || die "aptly does not publish $codename component $c after adding it"
		added+=("$snapshot")
	done
	snapshots[$codename]="${added[*]}"
done

for codename in "${!snapshots[@]}"; do
	# shellcheck disable=SC2086 # expect and pruned_specs hold space-separated specs
	verify_published "$codename" ${expect[$codename]:-} ${pruned_specs[$codename]:-}
	printf '%s %s\n' "$codename" "${snapshots[$codename]}"
done
if [[ -n $report ]]; then
	printf '%s\n' "${rows[@]}" | sort -u >"$report"
fi
if [[ -n $pruned_file ]]; then
	: >"$pruned_file"
	if ((${#pruned_rows[@]})); then
		printf '%s\n' "${pruned_rows[@]}" | sort -u >"$pruned_file"
	fi
fi
