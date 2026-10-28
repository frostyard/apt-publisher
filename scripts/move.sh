#!/usr/bin/env bash
# Move every published package whose component differs from its producer's
# registration (config/producers.tsv column 6) to the registered component
# (core ADR-0059, step 5). All versions and architectures of a name move
# together, and no package version changes. For each codename the packages
# leave one component and appear in the other in one publication: one signed
# Release, as one recoverable transaction (commit_publications).
#
# The script has no direction. When a registration goes back to main, the
# same run moves image -> main: that is how a move is reverted, by a forward
# change. A snapshot taken before a move is not a rollback target
# (switch.sh refuses it).
#
# A name with no registered producer stays where it is. A name in more than
# one component is refused: the one-component rule is broken, so repair that
# first. Pool files are never deleted (-skip-cleanup); the files under
# pool/main stay, and aptly uploads copies under pool/image.
#
# Every working repository must hold exactly the package set of its published
# snapshot, because the move starts from what the bucket serves. A run that
# died after saving its repository changes but before publishing leaves a
# repository that differs; --rebuild rebuilds it from the published snapshot
# (rebuild_repo) and carries on, after you have inspected the refusal.
#
# With --dry-run nothing is reconciled, changed or saved: it prints the plan
# and stops. A live run validates every codename before it changes any.
#
# A move changes two components, and its publication is saved before it
# becomes visible. A move marker (txn/move-CODENAME, written before the
# publication, removed after it) lets the next run of any script settle it
# (reconcile_state): complete a move that became visible, and undo one that
# did not, by rebuilding the changed working repositories from the published
# snapshots. Then the move can simply run again.
#
# Prints "CODENAME SNAPSHOT SNAPSHOT" on stdout for each published codename.
# With --report FILE, writes "codename name version arch component" rows for
# apt-canary.sh: only the newest version of each (codename, name, arch), so
# the canary does not download every moved file through the CDN; the deep
# read-back already checks every file's MD5.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: move.sh [--codename CODENAME]... [--dry-run] [--rebuild] [--report FILE]

  --codename  move only this codename (repeatable); default: every codename
  --dry-run   print the plan ("move CODENAME NAME VERSION ARCH FROM -> TO")
              and stop; nothing is reconciled, changed or saved
  --rebuild   rebuild a working repository that differs from its published
              snapshot, instead of refusing
  --report    write the newest moved version of each package as TSV to FILE
EOF
	exit 2
}

codenames=() dry_run=0 rebuild=0 report=''
while (($#)); do
	case $1 in
	--codename) codenames+=("${2:?}") && shift ;;
	--dry-run) dry_run=1 ;;
	--rebuild) rebuild=1 ;;
	--report) report=${2:?} && shift ;;
	*) usage ;;
	esac
	shift
done
require dpkg
if ((${#codenames[@]} == 0)); then
	mapfile -t codenames < <(awk -F'\t' '!/^#/ && NF { print $1 }' "$APT_CODENAMES_FILE")
fi
for codename in "${codenames[@]}"; do
	codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
done

# repo_set REPO prints the repository's packages as sorted "name version arch".
# An empty repository gives nothing; any other aptly error is fatal.
repo_set() {
	local out
	if ! out=$(aptly_ repo search -format='{{.Package}} {{.Version}} {{.Architecture}}' "$1" 2>&1); then
		[[ $out == *"no results"* ]] || die "cannot search repository $1: $out"
		return 0
	fi
	LC_ALL=C sort -u <<<"$out"
}

aptly_init

# --- plan: validate every codename before any change --------------------------
#
# plan[CODENAME] holds one tab-separated row per moved package:
# name, version, arch, from, to.
declare -A plan=()
rebuilt=0
for codename in "${codenames[@]}"; do
	if ((!dry_run)); then
		reconcile_state "$codename"
	fi
	configured=$(codename_components "$codename")
	declare -A where=() decided=()
	rows=''
	for component in ${configured//,/ }; do
		repo=$(repo_name "$codename" "$component")
		published=$(published_snapshot "$codename" "$component")
		have='' want=''
		if repo_exists "$repo"; then
			have=$(repo_set "$repo")
		fi
		if [[ -n $published ]]; then
			want=$(snapshot_set "$published")
		fi
		if [[ $have != "$want" ]]; then
			if ((!rebuild)); then
				diff_lines=$(diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") | head -n 6 || true)
				die "$repo does not hold the package set of its published snapshot ${published:-none}; the move starts from what the bucket serves, so nothing was changed. An earlier run may have died after it saved its repository changes: inspect, then run again with --rebuild. First differences (< repository, > snapshot):"$'\n'"$diff_lines"
			fi
			[[ -n $published ]] || die "$repo holds packages, but $codename publishes no $component snapshot to rebuild it from"
			if ((dry_run)); then
				log "dry run: would rebuild $repo from $published"
			else
				rebuild_repo "$codename" "$component" "$published"
				rebuilt=1
			fi
			have=$want
		fi
		while read -r name version arch; do
			[[ -n $name ]] || continue
			[[ $name =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die "$codename lists the package name $name, which the move cannot query safely"
			if [[ -n ${where[$name]:-} && ${where[$name]} != "$component" ]]; then
				die "$codename lists $name in both ${where[$name]} and $component; the one-component rule (core ADR-0059) is broken, so repair that first. Nothing was changed"
			fi
			where[$name]=$component
			if [[ -z ${decided[$name]:-} ]]; then
				decided[$name]=$(registered_component "$name")
				if [[ -z ${decided[$name]} ]]; then
					log "$codename: $name has no registered producer and stays in $component"
				elif ! in_csv "${decided[$name]}" "$configured"; then
					die "$name is registered for component ${decided[$name]}, which $codename does not publish. Nothing was changed"
				fi
			fi
			target=${decided[$name]}
			[[ -n $target && $target != "$component" ]] || continue
			rows+="$name"$'\t'"$version"$'\t'"$arch"$'\t'"$component"$'\t'"$target"$'\n'
		done <<<"$have"
	done
	unset where decided
	plan[$codename]=$(printf '%s' "$rows" | LC_ALL=C sort -u)
	if [[ -z ${plan[$codename]} ]]; then
		log "nothing to move in $codename"
		continue
	fi
	while IFS=$'\t' read -r name version arch from to; do
		log "move $codename $name $version $arch $from -> $to"
	done <<<"${plan[$codename]}"
done
if ((dry_run)); then
	log "dry run: nothing changed"
	exit 0
fi
if ((rebuilt)); then
	# Keep the cleanup even when a codename has nothing to move.
	state_save
fi

# --- apply -----------------------------------------------------------------------

report_rows=()
for codename in "${codenames[@]}"; do
	[[ -n ${plan[$codename]} ]] || continue
	configured=$(codename_components "$codename")
	declare -A pair_names=() changed=()
	expect=()
	while IFS=$'\t' read -r name version arch from to; do
		[[ " ${pair_names[$from:$to]:-} " == *" $name "* ]] || pair_names[$from:$to]+="$name "
		changed[$from]=1
		changed[$to]=1
		expect+=("$to/$name=$version" "!$from/$name=$version")
	done <<<"${plan[$codename]}"
	for component in ${configured//,/ }; do
		[[ -z ${changed[$component]:-} ]] || ensure_repo "$codename" "$component" >/dev/null
	done
	# One query per name selects every version and architecture.
	for pair in "${!pair_names[@]}"; do
		src=$(repo_name "$codename" "${pair%:*}")
		dst=$(repo_name "$codename" "${pair#*:}")
		read -ra move_names <<<"${pair_names[$pair]}"
		log "moving ${move_names[*]} from $src to $dst"
		aptly_ repo move "$src" "$dst" "${move_names[@]}" >&2
	done
	# The repositories must show the move before it is published.
	declare -A dst_sets=()
	while IFS=$'\t' read -r name version arch from to; do
		if has_package repo "$(repo_name "$codename" "$from")" "$name"; then
			die "$(repo_name "$codename" "$from") still holds $name after the move; nothing was published"
		fi
		[[ -n ${dst_sets[$to]+x} ]] || dst_sets[$to]=$(repo_set "$(repo_name "$codename" "$to")")
		grep -qxF -- "$name $version $arch" <<<"${dst_sets[$to]}" ||
			die "$(repo_name "$codename" "$to") lacks $name $version $arch after the move; nothing was published"
	done <<<"${plan[$codename]}"
	unset dst_sets

	# New snapshots of both changed components, and an empty one for any
	# other configured component the codename does not publish yet; then one
	# publication, one signed Release.
	commits=()
	snapshots=()
	changed_components=()
	marker=''
	for component in ${configured//,/ }; do
		[[ -n ${changed[$component]:-} ]] || continue
		changed_components+=("$component")
		snapshot=$(new_snapshot_name "$codename" "$component" move)
		aptly_ snapshot create "$snapshot" from repo "$(repo_name "$codename" "$component")" >/dev/null
		commits+=("$codename/$component=$snapshot")
		snapshots+=("$snapshot")
		marker+="$component $snapshot"$'\n'
	done
	others=$(missing_component_snapshots "$codename" move "${changed_components[@]}")
	if [[ -n $others ]]; then
		mapfile -t others_list <<<"$others"
		commits+=("${others_list[@]}")
		for spec in "${others_list[@]}"; do
			snapshots+=("${spec#*=}")
		done
	fi
	# The move changes two components, and commit_publications saves the
	# repositories before it publishes. The marker, saved with them, lets the
	# next run undo a move that never became visible (settle_move): else a
	# publication of one component would strand the move in the other.
	printf '%s' "$marker" >"$(move_file "$codename")"
	commit_publications "${commits[@]}"
	drop_move "$codename"
	state_save
	verify_published "$codename" --deep "${expect[@]}"
	printf '%s %s\n' "$codename" "${snapshots[*]}"

	# The canary installs the newest moved version of each package only;
	# versions compare as dpkg does (epochs, ~).
	declare -A newest=()
	while IFS=$'\t' read -r name version arch from to; do
		key=$name$'\t'$arch
		if [[ -z ${newest[$key]:-} ]] || dpkg --compare-versions "$version" gt "${newest[$key]%%$'\t'*}"; then
			newest[$key]=$version$'\t'$to
		fi
	done <<<"${plan[$codename]}"
	for key in "${!newest[@]}"; do
		report_rows+=("$codename"$'\t'"${key%%$'\t'*}"$'\t'"${newest[$key]%%$'\t'*}"$'\t'"${key#*$'\t'}"$'\t'"${newest[$key]#*$'\t'}")
	done
	unset pair_names changed newest
done

if [[ -n $report ]]; then
	: >"$report"
	if ((${#report_rows[@]})); then
		printf '%s\n' "${report_rows[@]}" | LC_ALL=C sort -u >"$report"
	fi
fi
