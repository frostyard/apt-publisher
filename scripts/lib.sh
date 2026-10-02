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
#   txn/   pending-<codename>: the snapshot a publication was about to make
#          visible, so an interrupted run can be completed (reconcile_state).

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

pending_file() { printf '%s/txn/pending-%s' "$APTLY_ROOT" "$1"; }

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

# pending_snapshot CODENAME prints the recorded pending snapshot, if it
# exists in the database.
pending_snapshot() {
	local f snapshot
	f=$(pending_file "$1")
	[[ -f $f ]] || return 0
	snapshot=$(<"$f")
	if snapshot_exists "$snapshot"; then
		printf '%s\n' "$snapshot"
	fi
}

# --- repositories, snapshots, publications ---------------------------------------

repo_name() { printf 'frostyard-%s' "$1"; }

# ensure_repo CODENAME creates the local repository for CODENAME if needed
# and prints its name.
ensure_repo() {
	local repo
	repo=$(repo_name "$1")
	if ! aptly_ repo show "$repo" >/dev/null 2>&1; then
		aptly_ repo create -distribution="$1" -component="$APT_COMPONENT" "$repo" >/dev/null
	fi
	printf '%s\n' "$repo"
}

# rebuild_repo CODENAME SNAPSHOT replaces the codename's working repository
# with SNAPSHOT's contents, so later publications build on it.
rebuild_repo() {
	local repo
	repo=$(repo_name "$1")
	if aptly_ repo show "$repo" >/dev/null 2>&1; then
		# -force: the repository's snapshots stay; only the working copy goes.
		aptly_ repo drop -force "$repo" >/dev/null
	fi
	aptly_ repo create -distribution="$1" -component="$APT_COMPONENT" "$repo" from snapshot "$2" >/dev/null
	log "rebuilt $repo from $2"
}

# new_snapshot_name CODENAME LABEL prints an unused snapshot name.
new_snapshot_name() {
	local label base name n=1
	label=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '-')
	base="$1-$(date -u +%Y%m%dT%H%M%SZ)-$label"
	name=$base
	while snapshot_exists "$name"; do
		n=$((n + 1))
		name=$base.$n
	done
	printf '%s\n' "$name"
}

# published_snapshot CODENAME prints the snapshot aptly's database says the
# codename is published from, or nothing.
published_snapshot() {
	aptly_ publish list -json | jq -r --arg p "$APT_PREFIX" --arg d "$1" --arg c "$APT_COMPONENT" \
		'.[] | select(.Storage == "s3:r2" and .Prefix == $p and .Distribution == $d) | .Sources[] | select(.Component == $c) | .Name'
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

# bucket_set CODENAME prints the packages the bucket's indexes list, as
# sorted "name version arch".
bucket_set() {
	local arch tmp
	tmp=$(mktemp)
	for arch in $(codename_field "$1" 3 | tr , ' '); do
		rclone cat "r2:$APT_BUCKET/$APT_PREFIX/dists/$1/$APT_COMPONENT/binary-$arch/Packages" >>"$tmp" ||
			die "cannot read the published $1 $arch index"
		printf '\n' >>"$tmp"
	done
	stanzas_tsv "$tmp" >"$tmp.tsv" ||
		die "the published $1 indexes are malformed; inspect them, then recover with switch.sh --force"
	awk -F'\t' '{ print $4, $5, $6 }' "$tmp.tsv" | LC_ALL=C sort -u
	rm -f -- "$tmp" "$tmp.tsv"
}

# reconcile_state CODENAME runs before any change to CODENAME. It proves
# that aptly's database describes what the bucket serves, comparing package
# sets because a Release file changes on every publication:
#   - the bucket lists exactly the published snapshot: current; a pending
#     marker left by a run that failed before becoming visible is dropped;
#   - the bucket lists exactly the pending snapshot: a run published it but
#     failed before saving, so the publication is completed;
#   - anything else (lost, older or foreign state) is refused.
reconcile_state() {
	local codename=$1 published pending bucket
	published=$(published_snapshot "$codename")
	pending=$(pending_snapshot "$codename")
	if ! remote_has_dist "$codename"; then
		[[ -z $published ]] ||
			die "aptly's database publishes $codename from $published, but the bucket has no dists/$codename"
		rm -f -- "$(pending_file "$codename")"
		return 0
	fi
	bucket=$(bucket_set "$codename")
	if [[ -n $published && $(snapshot_set "$published") == "$bucket" ]]; then
		rm -f -- "$(pending_file "$codename")"
		return 0
	fi
	if [[ -n $pending && $(snapshot_set "$pending") == "$bucket" ]]; then
		log "completing the interrupted publication of $codename from $pending"
		publish_snapshot "$codename" "$pending"
		rm -f -- "$(pending_file "$codename")"
		state_save
		return 0
	fi
	die "the bucket's $APT_PREFIX/dists/$codename does not match aptly's database (published: ${published:-none}, pending: ${pending:-none}); the state is lost or stale, or another writer changed the bucket. Inspect it, then recover with switch.sh --force"
}

# force_overwrite=1 (switch.sh --force) lets aptly replace pool files whose
# bucket copy differs from the local pool, repairing corrupted objects.
force_overwrite=0

# publish_snapshot CODENAME SNAPSHOT points CODENAME at SNAPSHOT: an atomic
# switch when aptly already publishes it, otherwise a first publication.
# Pool files are never deleted (-skip-cleanup). Callers reconcile first.
publish_snapshot() {
	local codename=$1 snapshot=$2
	local common=(-batch "-gpg-key=$APT_SIGNING_KEY_FPR" -skip-contents -component="$APT_COMPONENT")
	if ((force_overwrite)); then
		common+=(-force-overwrite)
	fi
	if [[ -n $(published_snapshot "$codename") ]]; then
		log "switching $codename to $snapshot"
		aptly_ publish switch "${common[@]}" -skip-cleanup "$codename" "$APT_TARGET" "$snapshot" >&2
	else
		log "first publication of $codename from $snapshot"
		aptly_ publish snapshot "${common[@]}" -acquire-by-hash \
			-distribution="$codename" \
			-architectures="$(codename_field "$codename" 3)" \
			-origin="$APT_ORIGIN" -label="$APT_LABEL" \
			"$snapshot" "$APT_TARGET" >&2
	fi
}

# commit_publications CODENAME=SNAPSHOT... makes the snapshots visible as
# one recoverable transaction: record them as pending and save, publish,
# clear the markers and save again. Repository changes made before the call
# are saved with the markers.
commit_publications() {
	local pair
	for pair in "$@"; do
		printf '%s\n' "${pair#*=}" >"$(pending_file "${pair%%=*}")"
	done
	state_save
	for pair in "$@"; do
		publish_snapshot "${pair%%=*}" "${pair#*=}"
	done
	for pair in "$@"; do
		rm -f -- "$(pending_file "${pair%%=*}")"
	done
	state_save
}

# --- read-back verification ------------------------------------------------------

# release_sha256 RELEASE PATH prints the SHA256 of PATH listed in RELEASE.
release_sha256() {
	awk -v p="$2" '/^[^ ]/ { s = ($0 == "SHA256:") } s && $3 == p { print $1; found = 1 } END { exit !found }' "$1"
}

# verify_published CODENAME [--deep] [NAME=VERSION | !NAME=VERSION]...
# reads the published suite back from the bucket and checks:
#   - the InRelease signature, its codename and every index hash;
#   - NAME=VERSION is listed and each of its files in the bucket matches
#     its SHA256; !NAME=VERSION is not listed;
#   - with --deep, every listed file exists in the bucket with the index's
#     MD5 (aptly uploads each file in one part, so the ETag is the MD5).
verify_published() {
	local codename=$1 deep=0
	shift
	if [[ ${1:-} == --deep ]]; then
		deep=1
		shift
	fi
	local tmp dists arch path want got spec name version rows filename sha
	tmp=$(mktemp -d)
	dists="r2:$APT_BUCKET/$APT_PREFIX/dists/$codename"
	rclone cat "$dists/InRelease" >"$tmp/InRelease"
	gpgv --keyring "$APT_KEYRING" --output "$tmp/Release" "$tmp/InRelease" 2>"$tmp/gpgv.log" ||
		die "$codename InRelease is not signed by $APT_KEYRING: $(cat "$tmp/gpgv.log")"
	grep -qx "Codename: $codename" "$tmp/Release" || die "$codename Release names the wrong codename"
	: >"$tmp/stanzas.tsv"
	for arch in $(codename_field "$codename" 3 | tr , ' '); do
		path="$APT_COMPONENT/binary-$arch/Packages"
		want=$(release_sha256 "$tmp/Release" "$path") || die "$codename Release does not list $path"
		rclone cat "$dists/$path" >"$tmp/Packages-$arch"
		got=$(sha256sum <"$tmp/Packages-$arch" | cut -d' ' -f1)
		[[ $got == "$want" ]] || die "$codename $path does not match its Release hash"
		stanzas_tsv "$tmp/Packages-$arch" >>"$tmp/stanzas.tsv"
	done
	for spec in "$@"; do
		name=${spec#!}
		version=${name#*=}
		name=${name%%=*}
		rows=$(awk -F'\t' -v n="$name" -v v="$version" '$4 == n && $5 == v { print $1 "\t" $2 }' "$tmp/stanzas.tsv" | sort -u)
		if [[ $spec == !* ]]; then
			[[ -z $rows ]] || die "$codename still lists $name $version"
			continue
		fi
		[[ -n $rows ]] || die "$codename does not list $name $version"
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
	log "verified $codename${*:+: $*}"
}
