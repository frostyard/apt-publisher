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
# snapshot, because the move starts from what the bucket serves. A move that
# died is settled by the move marker (below), not by this check. A repository
# that differs without such a marker is drift; --rebuild rebuilds it from the
# published snapshot (rebuild_repo) and carries on, after you have inspected
# the refusal.
#
# With --dry-run nothing is reconciled, changed or saved: it prints the plan
# and stops. A live run validates every codename before it changes any.
#
# A move changes two components, and its publication is saved before it
# becomes visible. A move marker (txn/move-CODENAME) therefore holds the
# snapshot names and the plan, and is saved FIRST, before any repository is
# moved. The next run of any script settles it (reconcile_state): it
# completes a move that became visible, and undoes one that did not, by
# rebuilding the changed working repositories from the published snapshots.
# The marker is removed only after the read-back passes. A later move.sh run
# that finds a move completed by reconciliation verifies it and prints it, so
# the workflow's purge and canary still run. --recheck does the read-back for
# a codename without any change.
#
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: move.sh [--codename CODENAME]... [--dry-run] [--rebuild] [--report FILE]
       move.sh --recheck [--codename CODENAME]... [--report FILE]

  --codename  move only this codename (repeatable); default: every codename
  --dry-run   print the plan ("move CODENAME NAME VERSION ARCH FROM -> TO")
              and stop; nothing is reconciled, changed or saved
  --rebuild   rebuild a working repository that differs from its published
              snapshot, instead of refusing
  --report    write the newest moved version of each package as TSV to FILE
  --recheck   change nothing: read the published suite back (deep check),
              print each codename with its published snapshots, and report
              the newest version of each package in every component but
              main. Run it when a step after a move failed, or when a retry
              found nothing to move; it refuses --dry-run and --rebuild
EOF
	exit 2
}

codenames=() dry_run=0 rebuild=0 recheck=0 report=''
while (($#)); do
	case $1 in
	--codename) codenames+=("${2:?}") && shift ;;
	--dry-run) dry_run=1 ;;
	--rebuild) rebuild=1 ;;
	--recheck) recheck=1 ;;
	--report) report=${2:?} && shift ;;
	*) usage ;;
	esac
	shift
done
require dpkg
((!recheck || (!dry_run && !rebuild))) || die "--recheck changes nothing and cannot be combined with --dry-run or --rebuild"
if ((${#codenames[@]} == 0)); then
	mapfile -t codenames < <(awk -F'\t' '!/^#/ && NF { print $1 }' "$APT_CODENAMES_FILE")
fi
for codename in "${codenames[@]}"; do
	codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
done

# The move marker (move_file in lib.sh) holds "COMPONENT SNAPSHOT" lines for
# the changed components and "row NAME VERSION ARCH FROM TO" lines for the
# plan. marker_snapshots and marker_rows print the two kinds.
marker_snapshots() { awk '$1 != "row" && NF >= 2 { print $1, $2 }' <<<"$1"; }
marker_rows() { awk -v OFS='\t' '$1 == "row" && NF == 6 { print $2, $3, $4, $5, $6 }' <<<"$1"; }

report_rows=()

# marker_visible CODENAME MARKER: does aptly publish every snapshot the
# marker names?
marker_visible() {
	local component snapshot n=0
	while read -r component snapshot; do
		n=$((n + 1))
		[[ $(published_snapshot "$1" "$component") == "$snapshot" ]] || return 1
	done < <(marker_snapshots "$2")
	((n))
}

# add_report_rows CODENAME ROWS adds the report rows of the newest moved
# version of each (name, arch). ROWS holds one tab-separated moved package
# per line: name, version, arch, from, to. The canary installs these only;
# versions compare as dpkg does (epochs, ~).
add_report_rows() {
	local name version arch from to key
	local -A newest=()
	while IFS=$'\t' read -r name version arch from to; do
		[[ -n $name ]] || continue
		key=$name$'\t'$arch
		if [[ -z ${newest[$key]:-} ]] || dpkg --compare-versions "$version" gt "${newest[$key]%%$'\t'*}"; then
			newest[$key]=$version$'\t'$to
		fi
	done <<<"$2"
	for key in "${!newest[@]}"; do
		report_rows+=("$1"$'\t'"${key%%$'\t'*}"$'\t'"${newest[$key]%%$'\t'*}"$'\t'"${key#*$'\t'}"$'\t'"${newest[$key]#*$'\t'}")
	done
}

# write_report writes the report rows, sorted; empty when there are none.
write_report() {
	[[ -n $report ]] || return 0
	: >"$report"
	if ((${#report_rows[@]})); then
		printf '%s\n' "${report_rows[@]}" | LC_ALL=C sort -u >"$report"
	fi
}

aptly_init

# --- recheck: read back what is published, change nothing -------------------------
#
# For a failure after the move was saved (the read-back, the purge, the
# canary): a retry finds nothing to move, so it would print no codename and
# write no report. No reconcile, no change, no save.
if ((recheck)); then
	for codename in "${codenames[@]}"; do
		# A checked assignment: inside [[ $(...) ]] a failed query would read
		# as "not published" and skip the read-back.
		published_set=$(published_components "$codename") ||
			die "cannot query the publication of $codename"
		if [[ -z $published_set ]]; then
			log "$codename is not published; nothing to recheck"
			continue
		fi
		verify_published "$codename" --deep
		snapshots=()
		rows=''
		for component in $(codename_components "$codename" | tr , ' '); do
			published=$(published_snapshot "$codename" "$component")
			[[ -n $published ]] || die "aptly does not publish $codename component $component"
			snapshots+=("$published")
			[[ $component != main ]] || continue
			# The bucket's own index: it is what the canary installs from.
			have=$(bucket_set "$codename" "$component")
			while read -r name version arch; do
				[[ -n $name ]] || continue
				rows+="$name"$'\t'"$version"$'\t'"$arch"$'\t'"-"$'\t'"$component"$'\n'
			done <<<"$have"
		done
		printf '%s %s\n' "$codename" "${snapshots[*]}"
		add_report_rows "$codename" "$rows"
	done
	write_report
	exit 0
fi

[[ -r $APT_PRODUCERS_FILE ]] || die "cannot read the producers file $APT_PRODUCERS_FILE"

# --- plan: validate every codename before any change --------------------------
#
# plan[CODENAME] holds one tab-separated row per moved package:
# name, version, arch, from, to.
declare -A plan=() recovered=()
rebuilt=0
for codename in "${codenames[@]}"; do
	if ((!dry_run)); then
		# Read the move marker first: reconcile_state settles and drops it.
		marker_before=''
		if [[ -f $(move_file "$codename") ]]; then
			marker_before=$(<"$(move_file "$codename")")
		fi
		reconcile_state "$codename"
		# A marker that reconciliation dropped while its snapshots are
		# published: an earlier move became visible and died before its
		# read-back. It is verified below; a move that was undone plans again.
		if [[ -n $marker_before && ! -f $(move_file "$codename") ]] && marker_visible "$codename" "$marker_before"; then
			recovered[$codename]=$marker_before
			log "an earlier move of $codename became visible and died before its read-back; it is verified below"
		fi
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

for codename in "${codenames[@]}"; do
	if [[ -n ${recovered[$codename]:-} ]]; then
		# The reconciliation completed the earlier move, so nothing is left
		# to plan; it still needs the read-back, and the workflow's purge
		# and canary need its codename and report rows.
		recovered_rows=$(marker_rows "${recovered[$codename]}")
		recovered_expect=()
		while IFS=$'\t' read -r name version arch from to; do
			[[ -n $name ]] || continue
			recovered_expect+=("$to/$name=$version" "!$from/$name=$version")
		done <<<"$recovered_rows"
		# Reconciliation dropped the marker. Put it back until the read-back
		# passes, so that a failure here can be retried the same way.
		printf '%s\n' "${recovered[$codename]}" >"$(move_file "$codename")"
		state_save
		verify_published "$codename" --deep "${recovered_expect[@]}"
		drop_move "$codename"
		state_save
		printf '%s %s\n' "$codename" "$(marker_snapshots "${recovered[$codename]}" | awk '{ printf "%s%s", sep, $2; sep = " " }')"
		add_report_rows "$codename" "$recovered_rows"
	fi
	[[ -n ${plan[$codename]} ]] || continue
	configured=$(codename_components "$codename")
	declare -A pair_names=() changed=() new_snapshot=()
	expect=()
	while IFS=$'\t' read -r name version arch from to; do
		[[ " ${pair_names[$from:$to]:-} " == *" $name "* ]] || pair_names[$from:$to]+="$name "
		changed[$from]=1
		changed[$to]=1
		expect+=("$to/$name=$version" "!$from/$name=$version")
	done <<<"${plan[$codename]}"

	# The move marker is durable before any moved repository is saved:
	# state_save writes the database before the markers, so a marker written
	# with the repositories could be missing when a run dies between the two,
	# and a later publication of one component would strand the move in the
	# other. Fix the snapshot names and the plan now, and save, while the
	# database holds no moved repository. settle_move undoes a move whose
	# snapshots are not published, also when they do not exist.
	changed_components=()
	marker=''
	for component in ${configured//,/ }; do
		[[ -n ${changed[$component]:-} ]] || continue
		changed_components+=("$component")
		new_snapshot[$component]=$(new_snapshot_name "$codename" "$component" move)
		marker+="$component ${new_snapshot[$component]}"$'\n'
	done
	while IFS=$'\t' read -r name version arch from to; do
		marker+="row $name $version $arch $from $to"$'\n'
	done <<<"${plan[$codename]}"
	printf '%s' "$marker" >"$(move_file "$codename")"
	state_save

	for component in "${changed_components[@]}"; do
		ensure_repo "$codename" "$component" >/dev/null
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

	# Snapshots of both changed components, with the names the marker holds,
	# and an empty one for any other configured component the codename does
	# not publish yet; then one publication, one signed Release.
	commits=()
	snapshots=()
	for component in "${changed_components[@]}"; do
		aptly_ snapshot create "${new_snapshot[$component]}" from repo "$(repo_name "$codename" "$component")" >/dev/null
		commits+=("$codename/$component=${new_snapshot[$component]}")
		snapshots+=("${new_snapshot[$component]}")
	done
	others=$(missing_component_snapshots "$codename" move "${changed_components[@]}")
	if [[ -n $others ]]; then
		mapfile -t others_list <<<"$others"
		commits+=("${others_list[@]}")
		for spec in "${others_list[@]}"; do
			snapshots+=("${spec#*=}")
		done
	fi
	commit_publications "${commits[@]}"
	# The marker stays until the read-back passes: a failure here is retried
	# by the recovered-move path above, with the read-back, purge and canary.
	verify_published "$codename" --deep "${expect[@]}"
	drop_move "$codename"
	state_save
	printf '%s %s\n' "$codename" "${snapshots[*]}"
	add_report_rows "$codename" "${plan[$codename]}"
	unset pair_names changed new_snapshot
done

write_report
