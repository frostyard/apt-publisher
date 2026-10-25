#!/usr/bin/env bash
# Point-in-time rollback: publish CODENAME from earlier snapshots and rebuild
# the working repository of each component you give from its snapshot, so
# later publications build on the rolled-back contents instead of restoring
# what was rolled back. Everything published to CODENAME after the snapshots
# is unpublished, including other producers' packages; republish a release to
# roll it forward. Pool files are never deleted.
#
# Give --snapshot for the components to roll back, each named for CODENAME and
# its component: CODENAME-TIME-LABEL for main, CODENAME-image-TIME-LABEL for
# image. A configured component without a snapshot is added empty when the
# codename is published without it (core ADR-0059: `publish switch` cannot add
# a component); otherwise the codename needs a snapshot for every component,
# and a codename that aptly does not publish yet needs all of them.
#
# To pull a single version instead, use withdraw.sh.
#
# --force skips reconcile_state and lets aptly overwrite pool files whose
# bucket copy differs: it replaces whatever the bucket serves for CODENAME
# with aptly's view. Use it only to recover after inspecting a refusal.
# --list prints snapshots, publications and pending markers instead.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: switch.sh --codename CODENAME --snapshot SNAPSHOT [--snapshot SNAPSHOT]... [--force]
       switch.sh --list

  --snapshot  one for each component to roll back; a configured component
              the published codename lacks is added empty
EOF
	exit 2
}

codename='' snapshots=() list=0 force=0
while (($#)); do
	case $1 in
	--codename) codename=${2:?} && shift ;;
	--snapshot) snapshots+=("${2:?}") && shift ;;
	--force) force=1 ;;
	--list) list=1 ;;
	*) usage ;;
	esac
	shift
done

if ((list)); then
	aptly_init
	aptly_ publish list
	aptly_ snapshot list -sort=time
	for f in "$APTLY_ROOT"/txn/pending-*; do
		[[ -f $f ]] || continue
		marker=${f##*/pending-}
		if [[ $marker == *-image ]]; then
			printf 'pending: %s/image -> %s\n' "${marker%-image}" "$(<"$f")"
		else
			printf 'pending: %s/main -> %s\n' "$marker" "$(<"$f")"
		fi
	done
	exit 0
fi

[[ -n $codename ]] || usage
((${#snapshots[@]})) || usage
codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
configured=$(codename_components "$codename")
declare -A by_component=()
for snapshot in "${snapshots[@]}"; do
	component=$(snapshot_component "$codename" "$snapshot") ||
		die "$snapshot was not created for $codename"
	in_csv "$component" "$configured" ||
		die "$snapshot is a $component snapshot, but $codename does not publish $component"
	[[ -z ${by_component[$component]:-} ]] ||
		die "got two snapshots for $codename component $component (${by_component[$component]} and $snapshot); give one for each of: ${configured//,/ }"
	by_component[$component]=$snapshot
done
given=()
for component in ${configured//,/ }; do
	[[ -z ${by_component[$component]:-} ]] || given+=("$component")
done

aptly_init
for snapshot in "${snapshots[@]}"; do
	snapshot_exists "$snapshot" || die "no snapshot named $snapshot"
done
# One package name belongs in one component (core ADR-0059): the given
# snapshots must not share a name, with or without --force. Nothing has
# changed yet.
if ((${#given[@]} > 1)); then
	overlap=$(for component in "${given[@]}"; do snapshot_names "${by_component[$component]}"; done |
		LC_ALL=C sort | uniq -d)
	[[ -z $overlap ]] || die "the snapshots publish ${overlap//$'\n'/ } in more than one component; pick snapshots that keep one name in one component"
fi
if ((force)); then
	log "warning: --force: not reconciling $codename with the bucket; overwriting differing pool files"
	drop_pending "$codename"
	# shellcheck disable=SC2034 # read by publish_snapshot in lib.sh
	force_overwrite=1
else
	reconcile_state "$codename"
fi
# A configured component without a snapshot is added empty when the codename
# is published without it; otherwise it needs a snapshot. Before any
# rebuild_repo.
published_set=$(published_components "$codename")
for component in ${configured//,/ }; do
	[[ -n ${by_component[$component]:-} ]] && continue
	if [[ -z $published_set ]] || in_csv "$component" "$published_set"; then
		die "$codename publishes ${configured//,/ }: give a snapshot for component $component too"
	fi
done
for component in "${given[@]}"; do
	rebuild_repo "$codename" "$component" "${by_component[$component]}"
done
specs=()
for component in "${given[@]}"; do
	specs+=("$codename/$component=${by_component[$component]}")
done
others=$(missing_component_snapshots "$codename" rollback "${given[@]}")
if [[ -n $others ]]; then
	mapfile -t others_list <<<"$others"
	specs+=("${others_list[@]}")
fi
commit_publications "${specs[@]}"
verify_published "$codename" --deep
printf '%s %s\n' "$codename" "${snapshots[*]}"
