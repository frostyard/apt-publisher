#!/usr/bin/env bash
# Shared helpers for the apt-publisher scripts. Source it; do not execute it.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/publisher.conf
. "$ROOT/config/publisher.conf"

: "${APTLY_ROOT:=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aptly}"
APTLY_CONF=$APTLY_ROOT/aptly.conf
# Publish target: the S3 endpoint named "r2" in aptly.conf, under APT_PREFIX.
APT_TARGET="s3:r2:$APT_PREFIX"

log() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require() {
	local tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null ||
			die "$tool is required (pinned tools: mise install; system tools: apt-get install)"
	done
}

in_csv() { [[ ",$2," == *",$1,"* ]]; }

# matches_globs NAME GLOB[,GLOB...]
matches_globs() {
	local glob globs
	IFS=, read -ra globs <<<"$2"
	for glob in "${globs[@]}"; do
		# shellcheck disable=SC2053 # the right-hand side is a glob on purpose
		[[ $1 == $glob ]] && return 0
	done
	return 1
}

# table_field FILE KEY COLUMN prints COLUMN of the row whose first column is
# KEY, and fails when no such row exists.
table_field() {
	awk -F'\t' -v k="$2" -v c="$3" \
		'!/^#/ && NF && $1 == k { print $c; found = 1 } END { exit !found }' "$1"
}
codename_field() { table_field "$APT_CODENAMES_FILE" "$1" "$2"; }
producer_field() { table_field "$APT_PRODUCERS_FILE" "$1" "$2"; }

# codename_for_major MAJOR prints the configured codename for a Debian major.
codename_for_major() {
	awk -F'\t' -v m="$1" '!/^#/ && NF && $2 == m { print $1; found = 1 } END { exit !found }' \
		"$APT_CODENAMES_FILE"
}

# --- components (core ADR-0059) -------------------------------------------------
#
# A codename publishes the components in column 4 of config/codenames.tsv:
# main, or main,image. Each component has its own working repository,
# snapshots, pending marker and pool path. aptly publishes them under one
# signed Release. `aptly publish switch` cannot add a component to a published
# codename, so a configured component the codename lacks is added with
# `publish source add` and `publish update` (publish_snapshot); removing one
# is refused.

# Every component the publisher knows; used to clear markers whatever the
# configuration says.
ALL_COMPONENTS="main image"

# codename_components CODENAME prints the configured components, comma-separated.
codename_components() { codename_field "$1" 4; }

# component_set CSV prints a comma list, sorted and without duplicates.
component_set() { tr , '\n' <<<"$1" | LC_ALL=C sort -u | paste -sd, -; }

# release_components RELEASE prints the components a Release file lists, as a
# component_set.
release_components() { component_set "$(sed -n 's/^Components: //p' "$1" | tr ' ' ,)"; }

# snapshot_component CODENAME SNAPSHOT prints the component SNAPSHOT was
# named for, and fails when the name matches neither pattern:
#   main   CODENAME-<UTC time>-<label>
#   image  CODENAME-image-<UTC time>-<label>
snapshot_component() {
	if [[ $2 =~ ^$1-image-[0-9]{8}T[0-9]{6}Z- ]]; then
		printf 'image\n'
	elif [[ $2 =~ ^$1-[0-9]{8}T[0-9]{6}Z- ]]; then
		printf 'main\n'
	else
		return 1
	fi
}

# registered_component NAME prints the component that NAME's producer is
# registered for (column 6 of APT_PRODUCERS_FILE; a producer matches when one
# of its column-2 globs does), and nothing when no producer matches. It dies
# when producers registered for different components match NAME: no component
# is then right, and a move or a rollback must not guess.
registered_component() {
	local repo patterns component found='' found_repo='' rows
	# Read the file with a checked command: a missing or unreadable file
	# must not read as "no registered producer".
	rows=$(awk -F'\t' '!/^#/ && NF' "$APT_PRODUCERS_FILE") ||
		die "cannot read the producers file $APT_PRODUCERS_FILE"
	while IFS=$'\t' read -r repo patterns _ _ _ component; do
		[[ -n $patterns ]] || continue
		matches_globs "$1" "$patterns" || continue
		if [[ -n $found && $found != "$component" ]]; then
			die "producers $found_repo ($found) and $repo ($component) register $1 for different components; fix config/producers.tsv"
		fi
		found=$component
		found_repo=$repo
	done <<<"$rows"
	[[ -z $found ]] || printf '%s\n' "$found"
}

# stanzas_tsv PACKAGES... prints one row per stanza:
# Filename SHA256 Size Package Version Architecture MD5sum
stanzas_tsv() {
	awk '
		BEGIN { RS = ""; FS = "\n"; OFS = "\t" }
		{
			delete f
			for (i = 1; i <= NF; i++)
				if (match($i, /^[A-Za-z0-9-]+: /)) f[substr($i, 1, RLENGTH - 2)] = substr($i, RLENGTH + 1)
			if (f["Filename"] == "" || f["SHA256"] == "") { print "stanza without Filename or SHA256: " f["Package"] > "/dev/stderr"; bad = 1; next }
			print f["Filename"], f["SHA256"], f["Size"], f["Package"], f["Version"], f["Architecture"], f["MD5sum"]
		}
		END { exit bad }' "$@"
}

# r2_env exports R2 credentials for aptly (AWS_*) and rclone (remote "r2")
# from the environment, so no secret is written to disk.
r2_env() {
	: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
	: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
	: "${APT_S3_ENDPOINT:=https://${R2_ACCOUNT_ID:?R2_ACCOUNT_ID or APT_S3_ENDPOINT is required}.r2.cloudflarestorage.com}"
	export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
	export AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
	export RCLONE_CONFIG_R2_TYPE=s3
	export RCLONE_CONFIG_R2_PROVIDER=$APT_RCLONE_PROVIDER
	export RCLONE_CONFIG_R2_ENDPOINT=$APT_S3_ENDPOINT
	export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
	export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
	export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

aptly_() { aptly -config="$APTLY_CONF" "$@"; }

# aptly_init writes aptly.conf and restores aptly's state from the state
# bucket. Every mutating script starts here, as if on a fresh runner.
aptly_init() {
	require aptly rclone jq gpg gpgv
	r2_env
	mkdir -p "$APTLY_ROOT"
	jq -n --arg root "$APTLY_ROOT" --arg bucket "$APT_BUCKET" --arg endpoint "$APT_S3_ENDPOINT" '{
		rootDir: $root,
		gpgProvider: "gpg",
		S3PublishEndpoints: {
			r2: { region: "auto", bucket: $bucket, endpoint: $endpoint, acl: "none" }
		}
	}' >"$APTLY_CONF"
	state_restore
}

# --- state ------------------------------------------------------------------
#
# aptly's state is three trees in the state bucket:
#   db/    aptly's database, mirrored; replaced files go to history/<time>/
#   pool/  aptly's package pool, append-only. aptly reads a pool file
#          whenever a snapshot it publishes references a package the public
#          bucket does not hold yet.
#   txn/   pending-<codename> (main) and pending-<codename>-image: the
#          snapshot a publication was about to make visible, so an interrupted
#          run can be completed (reconcile_state).
#          move-<codename>: written by move.sh and saved FIRST, while the
#          database holds no moved repository (state_save writes the database
#          before the markers, so a marker saved with the repositories could
#          be lost). One "component snapshot" line for each component it
#          changes, with the names its snapshots will get, and one
#          "row NAME VERSION ARCH FROM TO" line for each moved package. It is
#          removed after the publication. A move changes two components, so
#          a run that publishes one component only must not find them half
#          moved: reconcile_state undoes a move whose snapshots are not
#          published, also when they do not exist (settle_move).

state_remote() { printf 'r2:%s/%s' "$APT_STATE_BUCKET" "$APT_STATE_PATH"; }

state_restore() {
	log "restoring aptly state from $(state_remote)"
	mkdir -p "$APTLY_ROOT/txn"
	rclone sync --quiet "$(state_remote)/db" "$APTLY_ROOT/db"
	rclone copy --quiet --transfers 16 "$(state_remote)/pool" "$APTLY_ROOT/pool"
	rclone sync --quiet "$(state_remote)/txn" "$APTLY_ROOT/txn"
}

# state_save writes the pool, then the database, then the pending markers,
# so a saved marker never names a snapshot the saved database lacks.
state_save() {
	[[ -f $APTLY_ROOT/db/CURRENT ]] || die "refusing to save state: $APTLY_ROOT/db is not an aptly database"
	log "saving aptly state to $(state_remote)"
	local stamp
	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	if [[ -d $APTLY_ROOT/pool ]]; then
		rclone copy --quiet --transfers 16 "$APTLY_ROOT/pool" "$(state_remote)/pool"
	fi
	rclone sync --quiet --backup-dir "$(state_remote)/history/$stamp/db" \
		"$APTLY_ROOT/db" "$(state_remote)/db"
	rclone sync --quiet --backup-dir "$(state_remote)/history/$stamp/txn" \
		"$APTLY_ROOT/txn" "$(state_remote)/txn"
}

# pending_file CODENAME COMPONENT: the marker keeps the main path of a
# main-only codename; image has its own.
pending_file() {
	case $2 in
	main) printf '%s/txn/pending-%s' "$APTLY_ROOT" "$1" ;;
	*) printf '%s/txn/pending-%s-%s' "$APTLY_ROOT" "$1" "$2" ;;
	esac
}

# drop_pending CODENAME removes the markers of every component.
drop_pending() {
	local c
	for c in $ALL_COMPONENTS; do
		rm -f -- "$(pending_file "$1" "$c")"
	done
}

# move_file CODENAME: the marker of a move in progress (see the state notes).
move_file() { printf '%s/txn/move-%s' "$APTLY_ROOT" "$1"; }

# drop_move CODENAME removes the move marker.
drop_move() { rm -f -- "$(move_file "$1")"; }

# snapshot_exists SNAPSHOT. Not `aptly snapshot show`: it fails once the
# snapshot's source repository has been rebuilt (rebuild_repo). The list is
# read in full before searching: piped into `grep -q`, which exits at the
# first match, aptly (one write per line) can die of SIGPIPE, and pipefail
# then reports an existing snapshot as missing.
snapshot_exists() {
	local list
	list=$(aptly_ snapshot list -raw) || die "cannot list aptly snapshots"
	grep -qxF -- "$1" <<<"$list"
}

# pending_snapshot CODENAME COMPONENT prints the recorded pending snapshot,
# if it exists in the database.
pending_snapshot() {
	local f snapshot
	f=$(pending_file "$1" "$2")
	[[ -f $f ]] || return 0
	snapshot=$(<"$f")
	if snapshot_exists "$snapshot"; then
		printf '%s\n' "$snapshot"
	fi
}

# --- repositories, snapshots, publications ---------------------------------------

# repo_name CODENAME COMPONENT: frostyard-CODENAME for main (unchanged),
# frostyard-CODENAME-image for image.
repo_name() {
	case $2 in
	main) printf 'frostyard-%s' "$1" ;;
	*) printf 'frostyard-%s-%s' "$1" "$2" ;;
	esac
}

# ensure_repo CODENAME COMPONENT creates the local repository for the
# component if needed and prints its name.
ensure_repo() {
	local repo
	repo=$(repo_name "$1" "$2")
	if ! aptly_ repo show "$repo" >/dev/null 2>&1; then
		aptly_ repo create -distribution="$1" -component="$2" "$repo" >/dev/null ||
			die "cannot create the aptly repository $repo"
	fi
	printf '%s\n' "$repo"
}

# rebuild_repo CODENAME COMPONENT SNAPSHOT replaces the component's working
# repository with SNAPSHOT's contents, so later publications build on it.
rebuild_repo() {
	local repo
	repo=$(repo_name "$1" "$2")
	if aptly_ repo show "$repo" >/dev/null 2>&1; then
		# -force: the repository's snapshots stay; only the working copy goes.
		aptly_ repo drop -force "$repo" >/dev/null
	fi
	aptly_ repo create -distribution="$1" -component="$2" "$repo" from snapshot "$3" >/dev/null
	log "rebuilt $repo from $3"
}

# new_snapshot_name CODENAME COMPONENT LABEL prints an unused snapshot name.
new_snapshot_name() {
	local label base name n=1
	label=$(printf '%s' "$3" | tr -c 'A-Za-z0-9._-' '-')
	base="$1-"
	[[ $2 == main ]] || base+="$2-"
	base+="$(date -u +%Y%m%dT%H%M%SZ)-$label"
	name=$base
	while snapshot_exists "$name"; do
		n=$((n + 1))
		name=$base.$n
	done
	printf '%s\n' "$name"
}

# missing_component_snapshots CODENAME LABEL COMPONENT... prints
# "CODENAME/COMPONENT=SNAPSHOT" for every configured component that is not
# among the COMPONENTs and that aptly does not publish for CODENAME: a first
# publication needs a snapshot of every component, and a published codename
# that lacks a configured component gets it empty from the next run, because
# `publish switch` cannot add one. When aptly does not publish CODENAME at
# all, that is every such component; otherwise it is each configured
# component missing from the published ones. Each snapshot is taken from the
# component's working repository, which may be empty. With a main-only
# configuration and publication it prints nothing and changes nothing.
missing_component_snapshots() {
	local codename=$1 label=$2 c repo snapshot published
	local -a absent=()
	shift 2
	# Callers run this inside $(...), where errexit is off: every failure
	# returns explicitly, so a failed query never reads as "nothing published".
	published=$(published_components "$codename") || return 1
	for c in $(codename_components "$codename" | tr , ' '); do
		in_csv "$c" "$(IFS=,; printf '%s' "$*")" && continue
		in_csv "$c" "$published" && continue
		absent+=("$c")
	done
	((${#absent[@]})) || return 0
	for c in "${absent[@]}"; do
		repo=$(ensure_repo "$codename" "$c") || return 1
		snapshot=$(new_snapshot_name "$codename" "$c" "$label") || return 1
		aptly_ snapshot create "$snapshot" from repo "$repo" >/dev/null || return 1
		printf '%s/%s=%s\n' "$codename" "$c" "$snapshot"
	done
}

# repo_exists REPO reports whether aptly has a local repository of that name.
# The list is read in full (see snapshot_exists), and a failure is fatal: it
# is never read as "no repository".
repo_exists() {
	local list
	list=$(aptly_ repo list -raw) || die "cannot list aptly repositories"
	grep -qxF -- "$1" <<<"$list"
}

# has_package repo|snapshot NAME PACKAGE: does the repository or snapshot hold
# a package of that name, in any version? "No results" means no; any other
# aptly error is fatal.
has_package() {
	local out
	if out=$(aptly_ "$1" search -format='{{.Package}}' "$2" "$3" 2>&1); then
		return 0
	fi
	[[ $out == *"no results"* ]] && return 1
	die "cannot search $1 $2 for $3: $out"
}

# one_component_rule CODENAME COMPONENT NAME... refuses a package name that
# CODENAME already has in a component other than COMPONENT, in that
# component's working repository or in its published snapshot (core
# ADR-0059). Callers run it after reconcile_state and before adding packages.
one_component_rule() {
	local codename=$1 component=$2 other repo published name
	shift 2
	for other in $(codename_components "$codename" | tr , ' '); do
		[[ $other != "$component" ]] || continue
		repo=$(repo_name "$codename" "$other")
		published=$(published_snapshot "$codename" "$other")
		for name in "$@"; do
			if repo_exists "$repo" && has_package repo "$repo" "$name"; then
				die "$codename already publishes $name in component $other"
			fi
			if [[ -n $published ]] && has_package snapshot "$published" "$name"; then
				die "$codename already publishes $name in component $other"
			fi
		done
	done
}

# snapshot_names SNAPSHOT prints the package names in SNAPSHOT, sorted and
# unique. An empty snapshot gives nothing; any other aptly error is fatal.
snapshot_names() {
	local out
	if ! out=$(aptly_ snapshot search -format='{{.Package}}' "$1" 2>&1); then
		[[ $out == *"no results"* ]] || die "cannot search snapshot $1: $out"
		return 0
	fi
	LC_ALL=C sort -u <<<"$out"
}

# published_snapshot CODENAME COMPONENT prints the snapshot aptly's database
# says the component is published from, or nothing.
published_snapshot() {
	aptly_ publish list -json | jq -r --arg p "$APT_PREFIX" --arg d "$1" --arg c "$2" \
		'.[] | select(.Storage == "s3:r2" and .Prefix == $p and .Distribution == $d) | .Sources[] | select(.Component == $c) | .Name'
}

# published_components CODENAME prints the components aptly's database
# publishes for the codename, as a component_set; nothing when unpublished.
published_components() {
	local names
	names=$(aptly_ publish list -json | jq -r --arg p "$APT_PREFIX" --arg d "$1" \
		'.[] | select(.Storage == "s3:r2" and .Prefix == $p and .Distribution == $d) | .Sources[].Component') ||
		die "cannot list aptly's publications"
	component_set "${names//$'\n'/,}"
}

# snapshot_set SNAPSHOT prints its packages as sorted "name version arch".
snapshot_set() {
	snapshot_exists "$1" || die "no snapshot named $1"
	# search fails with "no results" on an empty snapshot.
	{ aptly_ snapshot search -format='{{.Package}} {{.Version}} {{.Architecture}}' "$1" 2>/dev/null || true; } |
		LC_ALL=C sort -u
}

# remote_has_dist CODENAME reports whether the bucket already serves
# dists/CODENAME. Listing errors are fatal, never "absent".
remote_has_dist() {
	local out
	out=$(rclone lsf --dirs-only "r2:$APT_BUCKET/$APT_PREFIX/dists/") ||
		die "cannot list r2:$APT_BUCKET/$APT_PREFIX/dists/"
	grep -qx "$1/" <<<"$out"
}

# bucket_set CODENAME COMPONENT prints the packages the bucket's indexes
# list for the component, as sorted "name version arch".
bucket_set() {
	local arch tmp
	tmp=$(mktemp)
	for arch in $(codename_field "$1" 3 | tr , ' '); do
		rclone cat "r2:$APT_BUCKET/$APT_PREFIX/dists/$1/$2/binary-$arch/Packages" >>"$tmp" ||
			die "cannot read the published $1 $2 $arch index"
		printf '\n' >>"$tmp"
	done
	stanzas_tsv "$tmp" >"$tmp.tsv" ||
		die "the published $1 $2 indexes are malformed; inspect them, then recover with switch.sh --force"
	awk -F'\t' '{ print $4, $5, $6 }' "$tmp.tsv" | LC_ALL=C sort -u
	rm -f -- "$tmp" "$tmp.tsv"
}

# settle_move CODENAME deals with the move marker, after reconcile_state has
# proved that the bucket serves the published snapshots (completing an
# interrupted publication first). The caller saves the state afterwards.
#   - The published snapshots of the marker's components are the marker's:
#     the move became visible. Drop the marker.
#   - Otherwise the move never became visible, but move.sh saved its changed
#     working repositories with the marker. A later run would add to one
#     component only and switch only that one, which strands the move in the
#     other component. Rebuild each marker component's working repository
#     from its published snapshot (empty when it has none), so the move can
#     simply run again, and drop the marker.
settle_move() {
	local codename=$1 f component snapshot published repo i visible=1
	local -a comps=() snaps=()
	f=$(move_file "$codename")
	[[ -f $f ]] || return 0
	# "component snapshot" lines; the "row ..." lines (the plan, which
	# move.sh reads) are not this function's.
	while read -r component snapshot _; do
		[[ -n $component && $component != row ]] || continue
		comps+=("$component")
		snaps+=("$snapshot")
	done <"$f"
	((${#comps[@]})) || die "the move marker $f is empty; inspect it, then recover with switch.sh --force"
	for i in "${!comps[@]}"; do
		published=$(published_snapshot "$codename" "${comps[i]}")
		[[ $published == "${snaps[i]}" ]] || visible=0
	done
	if ((visible)); then
		log "the interrupted move of $codename (${snaps[*]}) is visible; dropping its marker"
		drop_move "$codename"
		return 0
	fi
	for component in "${comps[@]}"; do
		published=$(published_snapshot "$codename" "$component")
		if [[ -n $published ]]; then
			rebuild_repo "$codename" "$component" "$published"
			continue
		fi
		repo=$(repo_name "$codename" "$component")
		if repo_exists "$repo"; then
			aptly_ repo drop -force "$repo" >/dev/null
		fi
		ensure_repo "$codename" "$component" >/dev/null
		log "rebuilt $repo empty: $codename publishes no $component snapshot"
	done
	drop_move "$codename"
	drop_pending "$codename"
	log "an interrupted move of $codename never became visible and was undone: rebuilt the working repositories of ${comps[*]} from the published snapshots; run the move again"
}

# reconcile_state CODENAME runs before any change to CODENAME. It proves
# that aptly's database describes what the bucket serves, comparing package
# sets because a Release file changes on every publication. The bucket must
# serve exactly the components aptly's database publishes, and, when that
# database publishes nothing, exactly the configured components. For each
# component it proves that aptly publishes, in the configured order:
#   - every component lists exactly its published snapshot: current; pending
#     markers left by a run that failed before becoming visible are dropped;
#   - else, with a marker present, every component lists its published or
#     its pending snapshot: a run published them but failed before saving,
#     so the pending snapshots are published again to complete it (this also
#     completes an interrupted addition of a component);
#   - anything else (lost, older or foreign state) is refused.
# A published codename that lacks a configured component is on its way to
# publishing it: the caller adds it empty. A configuration that would remove
# a component from a published codename is refused. Once the bucket is
# proved current, a move marker is settled (settle_move): dropped when its
# move became visible, undone when it did not. Every other refusal stands.
reconcile_state() {
	local codename=$1 configured published_set published pending bucket c
	local release have all_current=1 completable=1 markers=0 pubs='' pends=''
	local -a comps=() covered=() specs=() names=()
	local -A pend=()
	configured=$(component_set "$(codename_components "$codename")")
	published_set=$(published_components "$codename")
	if ! remote_has_dist "$codename"; then
		for c in $ALL_COMPONENTS; do
			published=$(published_snapshot "$codename" "$c")
			[[ -z $published ]] ||
				die "aptly's database publishes $codename from $published, but the bucket has no dists/$codename"
		done
		drop_pending "$codename"
		drop_move "$codename"
		return 0
	fi
	if [[ -n $published_set && $published_set != "$configured" ]]; then
		for c in ${published_set//,/ }; do
			in_csv "$c" "$configured" ||
				die "aptly's database publishes $codename with the components $published_set, but the configuration says $configured (core ADR-0059). Removing a component is a separate migration; nothing was changed"
		done
		log "aptly publishes $codename with $published_set; the configuration adds the rest, and this run adds them"
	fi
	release=$(mktemp)
	rclone cat "r2:$APT_BUCKET/$APT_PREFIX/dists/$codename/Release" >"$release" ||
		die "cannot read the published $codename Release"
	have=$(release_components "$release")
	rm -f -- "$release"
	if [[ $have != "$configured" && (-z $published_set || $have != "$published_set") ]]; then
		die "the bucket's $APT_PREFIX/dists/$codename does not match aptly's database: its Release lists the components ${have:-none}, but the configuration says $configured. Inspect it, then recover with switch.sh --force"
	fi
	IFS=, read -ra comps <<<"$(codename_components "$codename")"
	for c in "${comps[@]}"; do
		in_csv "$c" "$have" && covered+=("$c")
	done
	for c in "${covered[@]}"; do
		published=$(published_snapshot "$codename" "$c")
		pending=$(pending_snapshot "$codename" "$c")
		if [[ -f $(pending_file "$codename" "$c") ]]; then
			markers=1
		fi
		pend[$c]=$pending
		if ((${#covered[@]} > 1)); then
			pubs+="${pubs:+, }$c=${published:-none}"
			pends+="${pends:+, }$c=${pending:-none}"
		else
			pubs=${published:-none}
			pends=${pending:-none}
		fi
		bucket=$(bucket_set "$codename" "$c")
		if [[ -n $published && $(snapshot_set "$published") == "$bucket" ]]; then
			continue
		fi
		all_current=0
		if [[ -z $pending || $(snapshot_set "$pending") != "$bucket" ]]; then
			completable=0
		fi
	done
	if ((all_current)); then
		drop_pending "$codename"
		if [[ -f $(move_file "$codename") ]]; then
			settle_move "$codename"
			state_save
		fi
		return 0
	fi
	if ((markers && completable)); then
		for c in "${covered[@]}"; do
			if [[ -n ${pend[$c]} ]]; then
				specs+=("$c=${pend[$c]}")
				names+=("${pend[$c]}")
			fi
		done
		log "completing the interrupted publication of $codename from ${names[*]}"
		# The recovery publishes too, so it is gated like commit_publications.
		publish_key
		publish_snapshot "$codename" "${specs[@]}"
		drop_pending "$codename"
		settle_move "$codename"
		state_save
		return 0
	fi
	die "the bucket's $APT_PREFIX/dists/$codename does not match aptly's database (published: $pubs, pending: $pends); the state is lost or stale, or another writer changed the bucket. Inspect it, then recover with switch.sh --force"
}

# force_overwrite=1 (switch.sh --force) lets aptly replace pool files whose
# bucket copy differs from the local pool, repairing corrupted objects.
force_overwrite=0

# publish_snapshot CODENAME COMPONENT=SNAPSHOT... points the listed
# components of CODENAME at their snapshots, in one signed Release; components
# not listed stay as they are. When aptly already publishes the codename and
# every listed component, that is one atomic switch. Otherwise the listed
# components are staged first: the ones aptly does not publish yet are added
# (`publish source add`, which `publish switch` cannot do) and the published
# ones are updated, then one `publish update` writes the Release. A codename
# aptly does not publish at all gets a first publication, which needs a
# snapshot for every configured component. Pool files are never deleted
# (-skip-cleanup). Callers reconcile first.
publish_snapshot() {
	local codename=$1 pair c i found csv published csv_added csv_present out
	shift
	local -a comps=() snaps=() ordered=() configured=()
	local -a absent=() absent_snaps=() there=() there_snaps=()
	local -A seen=()
	IFS=, read -ra configured <<<"$(codename_components "$codename")"
	for pair in "$@"; do
		c=${pair%%=*}
		in_csv "$c" "$(IFS=,; printf '%s' "${configured[*]}")" ||
			die "$codename does not publish component $c"
		[[ -z ${seen[$c]:-} ]] || die "two snapshots for $codename component $c"
		seen[$c]=1
		comps+=("$c")
		snaps+=("${pair#*=}")
	done
	((${#comps[@]})) || die "no snapshot to publish for $codename"
	local common=(-batch "-gpg-key=$APT_SIGNING_KEY_FPR" -skip-contents)
	local extra=()
	if ((force_overwrite)); then
		extra+=(-force-overwrite)
	fi
	published=$(published_components "$codename")
	if [[ -n $published ]]; then
		for i in "${!comps[@]}"; do
			if in_csv "${comps[i]}" "$published"; then
				there+=("${comps[i]}")
				there_snaps+=("${snaps[i]}")
			else
				absent+=("${comps[i]}")
				absent_snaps+=("${snaps[i]}")
			fi
		done
		if ((${#absent[@]} == 0)); then
			csv=$(IFS=,; printf '%s' "${comps[*]}")
			log "switching $codename to ${snaps[*]}"
			aptly_ publish switch "${common[@]}" "-component=$csv" "${extra[@]}" -skip-cleanup \
				"$codename" "$APT_TARGET" "${snaps[@]}" >&2
			return 0
		fi
		# Staged changes from an earlier run would leak into this Release.
		if out=$(aptly_ publish source list "-prefix=$APT_TARGET" "$codename" 2>&1); then
			die "staged source changes exist for $codename (aptly publish source list); inspect them first"
		fi
		[[ $out == *"no source changes exist"* ]] ||
			die "cannot list the staged source changes of $codename: $out"
		csv_added=$(IFS=,; printf '%s' "${absent[*]}")
		log "adding component(s) $csv_added to $codename from ${absent_snaps[*]}"
		aptly_ publish source add "-component=$csv_added" "-prefix=$APT_TARGET" \
			"$codename" "${absent_snaps[@]}" >&2
		if ((${#there[@]})); then
			csv_present=$(IFS=,; printf '%s' "${there[*]}")
			aptly_ publish source update "-component=$csv_present" "-prefix=$APT_TARGET" \
				"$codename" "${there_snaps[@]}" >&2
		fi
		aptly_ publish update "${common[@]}" "${extra[@]}" -skip-cleanup \
			"$codename" "$APT_TARGET" >&2
		return 0
	fi
	for c in "${configured[@]}"; do
		found=''
		for i in "${!comps[@]}"; do
			if [[ ${comps[i]} == "$c" ]]; then found=${snaps[i]}; fi
		done
		[[ -n $found ]] || die "the first publication of $codename needs a snapshot for component $c"
		ordered+=("$found")
	done
	csv=$(IFS=,; printf '%s' "${configured[*]}")
	log "first publication of $codename from ${ordered[*]}"
	aptly_ publish snapshot "${common[@]}" "-component=$csv" "${extra[@]}" -acquire-by-hash \
		-distribution="$codename" \
		-architectures="$(codename_field "$codename" 3)" \
		-origin="$APT_ORIGIN" -label="$APT_LABEL" \
		"${ordered[@]}" "$APT_TARGET" >&2
}

# commit_publications CODENAME/COMPONENT=SNAPSHOT... makes the snapshots
# visible as one recoverable transaction: record them as pending and save,
# publish each codename in one call, clear the markers and save again.
# Repository changes made before the call are saved with the markers.
commit_publications() {
	local spec key codename component
	local -a order=() pairs=()
	local -A groups=()
	# First, so that a failed upload changes no state (core ADR-0059).
	publish_key
	for spec in "$@"; do
		key=${spec%%=*}
		[[ $key == */* ]] || die "invalid publication $spec (expected CODENAME/COMPONENT=SNAPSHOT)"
		codename=${key%%/*}
		component=${key#*/}
		printf '%s\n' "${spec#*=}" >"$(pending_file "$codename" "$component")"
		[[ -n ${groups[$codename]:-} ]] || order+=("$codename")
		groups[$codename]+="$component=${spec#*=} "
	done
	state_save
	for codename in "${order[@]}"; do
		read -ra pairs <<<"${groups[$codename]}"
		publish_snapshot "$codename" "${pairs[@]}"
	done
	for spec in "$@"; do
		key=${spec%%=*}
		rm -f -- "$(pending_file "${key%%/*}" "${key#*/}")"
	done
	state_save
}

# --- read-back verification ------------------------------------------------------

# release_sha256 RELEASE PATH prints the SHA256 of PATH listed in RELEASE.
release_sha256() {
	awk -v p="$2" '/^[^ ]/ { s = ($0 == "SHA256:") } s && $3 == p { print $1; found = 1 } END { exit !found }' "$1"
}

# verify_published CODENAME [--deep] [SPEC | !SPEC]...
# reads the published suite back from the bucket and checks:
#   - the InRelease signature, its codename, that its Components: are the
#     configured ones, and every index hash, for every component;
#   - SPEC, [COMPONENT/]NAME=VERSION, is listed and each of its files in the
#     bucket matches its SHA256; !SPEC is not listed. With a COMPONENT, only
#     that component's indexes count; without one, any component's;
#   - with --deep, every listed file of every component exists in the bucket
#     with the index's MD5 (aptly uploads each file in one part, so the ETag
#     is the MD5).
verify_published() {
	local codename=$1 deep=0
	shift
	if [[ ${1:-} == --deep ]]; then
		deep=1
		shift
	fi
	local tmp dists arch path want got spec name version rows filename sha component c have configured
	tmp=$(mktemp -d)
	dists="r2:$APT_BUCKET/$APT_PREFIX/dists/$codename"
	rclone cat "$dists/InRelease" >"$tmp/InRelease"
	gpgv --keyring "$APT_KEYRING" --output "$tmp/Release" "$tmp/InRelease" 2>"$tmp/gpgv.log" ||
		die "$codename InRelease is not signed by $APT_KEYRING: $(cat "$tmp/gpgv.log")"
	grep -qx "Codename: $codename" "$tmp/Release" || die "$codename Release names the wrong codename"
	configured=$(component_set "$(codename_components "$codename")")
	have=$(release_components "$tmp/Release")
	[[ $have == "$configured" ]] ||
		die "$codename Release lists the components ${have:-none}, but the configuration says $configured"
	: >"$tmp/stanzas.tsv"
	for c in $(codename_components "$codename" | tr , ' '); do
		for arch in $(codename_field "$codename" 3 | tr , ' '); do
			path="$c/binary-$arch/Packages"
			want=$(release_sha256 "$tmp/Release" "$path") || die "$codename Release does not list $path"
			rclone cat "$dists/$path" >"$tmp/Packages-$c-$arch"
			got=$(sha256sum <"$tmp/Packages-$c-$arch" | cut -d' ' -f1)
			[[ $got == "$want" ]] || die "$codename $path does not match its Release hash"
			stanzas_tsv "$tmp/Packages-$c-$arch" >"$tmp/stanzas-$c-$arch.tsv"
			# Column 8: the component the stanza came from.
			awk -F'\t' -v OFS='\t' -v c="$c" '{ print $0, c }' "$tmp/stanzas-$c-$arch.tsv" >>"$tmp/stanzas.tsv"
		done
	done
	for spec in "$@"; do
		name=${spec#!}
		version=${name#*=}
		name=${name%%=*}
		component=''
		if [[ $name == */* ]]; then
			component=${name%%/*}
			name=${name#*/}
		fi
		rows=$(awk -F'\t' -v n="$name" -v v="$version" -v c="$component" \
			'$4 == n && $5 == v && (c == "" || $8 == c) { print $1 "\t" $2 }' "$tmp/stanzas.tsv" | sort -u)
		if [[ $spec == !* ]]; then
			[[ -z $rows ]] || die "$codename still lists $name $version${component:+ in $component}"
			continue
		fi
		[[ -n $rows ]] || die "$codename does not list $name $version${component:+ in $component}"
		while IFS=$'\t' read -r filename sha; do
			got=$(rclone cat "r2:$APT_BUCKET/$APT_PREFIX/$filename" | sha256sum | cut -d' ' -f1)
			[[ $got == "$sha" ]] || die "$filename in the bucket does not match its SHA256"
		done <<<"$rows"
	done
	if ((deep)); then
		rclone lsjson -R --files-only --hash --hash-type md5 "r2:$APT_BUCKET/$APT_PREFIX/pool" |
			jq -r '.[] | ["pool/" + .Path, (.Hashes.md5 // "")] | @tsv' >"$tmp/objects.tsv"
		awk -F'\t' '
			NR == FNR { md5[$1] = $2; next }
			!($1 in md5) { print "missing from the bucket: " $1; bad = 1; next }
			md5[$1] != $7 { print "MD5 mismatch in the bucket: " $1; bad = 1 }
			END { exit bad }' "$tmp/objects.tsv" "$tmp/stanzas.tsv" >&2 ||
			die "$codename references pool files the bucket does not hold intact"
	fi
	rm -rf -- "$tmp"
	verify_key
	log "verified $codename${*:+: $*}"
}

# --- published key (core ADR-0059) -----------------------------------------------
#
# The binary keyring keys/frostyard.gpg is served at debian/frostyard.gpg, and
# hosts install it as /etc/apt/keyrings/frostyard.gpg. The object sits outside
# dists/ and pool/, so aptly never touches it, and this repository is its only
# writer: no other workflow, script or tool may write it.

key_object() { printf 'r2:%s/%s/frostyard.gpg' "$APT_BUCKET" "$APT_PREFIX"; }

# bucket_key_matches reports whether the bucket's key object is readable and
# byte-identical to $APT_KEYRING.
bucket_key_matches() {
	local tmp rc=0
	tmp=$(mktemp)
	if rclone cat "$(key_object)" >"$tmp" 2>/dev/null; then
		cmp -s -- "$tmp" "$APT_KEYRING" || rc=1
	else
		rc=1
	fi
	rm -f -- "$tmp"
	return "$rc"
}

# publish_key uploads the keyring when the bucket copy is missing, unreadable
# or different, then reads it back and compares the bytes.
publish_key() {
	[[ -f $APT_KEYRING ]] || die "cannot read the keyring $APT_KEYRING"
	if bucket_key_matches; then
		log "published key is current"
		return 0
	fi
	# --ignore-times: rclone skips a copy whose size and modification time
	# match, but the bytes were just found to differ.
	rclone copyto --ignore-times "$APT_KEYRING" "$(key_object)" || die "cannot upload the key to $(key_object)"
	bucket_key_matches || die "the key in the bucket differs from $APT_KEYRING after the upload"
	log "uploaded the published key"
}

# verify_key reads the key object back, changing nothing, and dies when it is
# missing or differs from $APT_KEYRING.
verify_key() {
	bucket_key_matches || die "the published key $(key_object) is missing or differs from $APT_KEYRING"
}
