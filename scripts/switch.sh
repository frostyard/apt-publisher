#!/usr/bin/env bash
# Point-in-time rollback: publish CODENAME from an earlier SNAPSHOT and
# rebuild the codename's working repository from it, so later publications
# build on the rolled-back contents instead of restoring what was rolled
# back. Everything published to CODENAME after SNAPSHOT is unpublished,
# including other producers' packages; republish a release to roll it
# forward. Pool files are never deleted.
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
usage: switch.sh --codename CODENAME --snapshot SNAPSHOT [--force]
       switch.sh --list
EOF
	exit 2
}

codename='' snapshot='' list=0 force=0
while (($#)); do
	case $1 in
	--codename) codename=${2:?} && shift ;;
	--snapshot) snapshot=${2:?} && shift ;;
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
		[[ -f $f ]] && printf 'pending: %s -> %s\n' "${f##*/pending-}" "$(<"$f")"
	done
	exit 0
fi

[[ -n $codename && -n $snapshot ]] || usage
codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
[[ $snapshot == "$codename"-* ]] || die "$snapshot was not created for $codename"

aptly_init
snapshot_exists "$snapshot" || die "no snapshot named $snapshot"
if ((force)); then
	log "warning: --force: not reconciling $codename with the bucket; overwriting differing pool files"
	rm -f -- "$(pending_file "$codename")"
	# shellcheck disable=SC2034 # read by publish_snapshot in lib.sh
	force_overwrite=1
else
	reconcile_state "$codename"
fi
rebuild_repo "$codename" "$snapshot"
commit_publications "$codename=$snapshot"
verify_published "$codename" --deep
printf '%s %s\n' "$codename" "$snapshot"
