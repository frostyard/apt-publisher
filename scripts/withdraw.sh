#!/usr/bin/env bash
# Withdraw one package version, or every request of a batch file, from one
# codename: remove each version from the working repository of the component
# that holds it, snapshot each changed component, and publish them in one
# signed Release, leaving every other package and component as it is. A
# configured component that the codename does not publish yet is added empty
# in the same publication (core ADR-0059). The files stay in the pool.
# Republishing the same release adds them back.
#
# A batch is a file in $APT_WITHDRAWALS_DIR with one "NAME VERSION [ARCH]"
# request row per line. Every row is resolved and checked before anything
# changes: the whole batch is withdrawn, or nothing is. The single mode is a
# batch of one request row, so both modes share one code path.
#
# --dry-run resolves the plan from the published suite alone: it reads and
# verifies dists/CODENAME/InRelease under $APT_PUBLIC_URL, so it needs no
# credentials, no aptly and no state, and it changes nothing. A live run
# reconciles aptly's state before it changes any repository.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: withdraw.sh --codename CODENAME --package NAME --version VERSION [--arch ARCH] [--dry-run]
       withdraw.sh --codename CODENAME --batch NAME [--dry-run]

  --arch     withdraw only this architecture; default: every architecture
  --batch    a file in the withdrawals directory, one "NAME VERSION [ARCH]"
             request row per line; a line starting with # is a comment
  --dry-run  print the plan from the published index and change nothing
EOF
	exit 2
}

codename='' name='' version='' arch='' batch='' dry_run=0
while (($#)); do
	case $1 in
	--codename) codename=${2:?} && shift ;;
	--package) name=${2:?} && shift ;;
	--version) version=${2:?} && shift ;;
	--arch) arch=${2:?} && shift ;;
	--batch) batch=${2:?} && shift ;;
	--dry-run) dry_run=1 ;;
	*) usage ;;
	esac
	shift
done
[[ -n $codename ]] || usage
if [[ -n $batch ]]; then
	[[ -z $name && -z $version && -z $arch ]] || usage
else
	[[ -n $name && -n $version ]] || usage
fi
codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
IFS=, read -ra components <<<"$(codename_components "$codename")"

# --- the requests: one "NAME<TAB>VERSION<TAB>ARCH" row each ----------------------
#
# The fields keep the shapes the aptly query needs: a plain package
# reference, an apt version and an architecture. A row without an
# architecture covers every architecture of that version.

declare -A seen=()
requests=()
# Where a request row came from, for the refusals: empty in the single mode,
# "FILE line N: " in the batch mode.
add_request() {
	local rname=$1 rversion=$2 rarch=${3:-} where=${4:-} key
	[[ $rname =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die "${where}invalid package name $rname"
	[[ $rversion =~ ^[A-Za-z0-9.+~:-]+$ ]] || die "${where}invalid version $rversion"
	[[ -z $rarch || $rarch =~ ^[a-z0-9]+$ ]] || die "${where}invalid architecture $rarch"
	key=$rname$'\t'$rversion$'\t'$rarch
	[[ -z ${seen[$key]:-} ]] || die "${where}duplicate request $rname $rversion${rarch:+ $rarch}"
	seen[$key]=1
	requests+=("$key")
}

if [[ -n $batch ]]; then
	# A batch name is one file name in the withdrawals directory: no path,
	# so a request can never name a file outside it.
	[[ $batch =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid batch name $batch"
	batch_file=$APT_WITHDRAWALS_DIR/$batch
	[[ -f $batch_file && -r $batch_file ]] || die "cannot read the batch file $batch_file"
	lineno=0
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=${line%$'\r'}
		if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
			continue
		fi
		read -ra fields <<<"$line"
		((${#fields[@]} >= 2 && ${#fields[@]} <= 3)) ||
			die "$batch_file line $lineno: expected NAME VERSION [ARCH], got ${#fields[@]} fields"
		add_request "${fields[0]}" "${fields[1]}" "${fields[2]:-}" "$batch_file line $lineno: "
	done <"$batch_file"
	((${#requests[@]})) || die "$batch_file lists no request row"
else
	add_request "$name" "$version" "$arch"
fi

# --- the package sets: what the codename publishes now --------------------------
#
# A dry run reads the public suite, which is what the bucket serves and what
# the plan is resolved against; a live run reads aptly's working
# repositories, after reconciliation proves they are current.

declare -A sets=()

# public_suite CODENAME fetches the published InRelease into a temporary
# directory and verifies it; its signed Release stays there. A codename the
# bucket does not serve reads as such, not as a credential error.
public_tmp='' public_release=''
public_suite() {
	local codename=$1 url
	url=$APT_PUBLIC_URL/dists/$codename
	public_tmp=$(mktemp -d)
	# shellcheck disable=SC2064 # the path is expanded now, the trap runs later
	trap "rm -rf -- '$public_tmp'" EXIT
	public_release=$public_tmp/Release
	curl -fsSL -o "$public_tmp/InRelease" -- "$url/InRelease" ||
		die "$codename is not published at $APT_PUBLIC_URL"
	gpgv --keyring "$APT_KEYRING" --output "$public_release" "$public_tmp/InRelease" 2>"$public_tmp/gpgv.log" ||
		die "$codename InRelease is not signed by $APT_KEYRING: $(cat "$public_tmp/gpgv.log")"
	grep -qx "Codename: $codename" "$public_release" || die "$codename Release names the wrong codename"
}

# public_component_set CODENAME COMPONENT prints the component's published
# packages as sorted "name version arch". Each index must match the SHA256
# the signed Release lists for it, so the plan is resolved from what clients
# install, not from a cached copy.
public_component_set() {
	local codename=$1 component=$2 all arch path want index
	all=$public_tmp/$component.Packages
	: >"$all"
	for arch in $(codename_field "$codename" 3 | tr , ' '); do
		path=$component/binary-$arch/Packages
		index=$public_tmp/$component-binary-$arch.Packages
		curl -fsSL -o "$index" -- "$APT_PUBLIC_URL/dists/$codename/$path" ||
			die "cannot read $APT_PUBLIC_URL/dists/$codename/$path"
		want=$(release_sha256 "$public_release" "$path") || die "$codename Release does not list $path"
		[[ $(sha256sum <"$index" | cut -d' ' -f1) == "$want" ]] ||
			die "$APT_PUBLIC_URL/dists/$codename/$path does not match its Release hash"
		cat "$index" >>"$all"
		printf '\n' >>"$all"
	done
	stanzas_tsv "$all" >"$all.tsv" || die "the published $codename $component indexes are malformed"
	awk -F'\t' '{ print $4, $5, $6 }' "$all.tsv" | LC_ALL=C sort -u
}

if ((dry_run)); then
	require curl gpgv
	public_suite "$codename"
	for c in "${components[@]}"; do
		sets[$c]=$(public_component_set "$codename" "$c")
	done
else
	aptly_init
	reconcile_state "$codename"
	for c in "${components[@]}"; do
		sets[$c]=$(repo_set "$(ensure_repo "$codename" "$c")")
	done
fi

# --- the plan: resolve every request before anything changes --------------------
#
# plan[COMPONENT] holds the "name version arch" lines of that component, and
# queries[COMPONENT] the aptly queries that remove them, one per request row.
# A component whose plan is empty does not change.

declare -A plan=() queries=()
for request in "${requests[@]}"; do
	IFS=$'\t' read -r qname qversion qarch <<<"$request"
	query="$qname (= $qversion)"
	[[ -z $qarch ]] || query+=" {$qarch}"
	found=()
	for c in "${components[@]}"; do
		while read -r sname sversion sarch; do
			[[ -n $sname ]] || continue
			[[ $sname == "$qname" && $sversion == "$qversion" ]] || continue
			[[ -z $qarch || $sarch == "$qarch" ]] || continue
			plan[$c]="${plan[$c]:-}$sname $sversion $sarch"$'\n'
			if ((${#found[@]} == 0)) || [[ ${found[${#found[@]} - 1]} != "$c" ]]; then
				found+=("$c")
			fi
		done <<<"${sets[$c]}"
	done
	if ((${#found[@]} == 0)); then
		# A main-only codename keeps the message it had before components.
		if [[ $(codename_components "$codename") == main ]]; then
			die "$(repo_name "$codename" main) has no $query"
		fi
		die "$codename has no $query in any component"
	fi
	if ((${#found[@]} > 1)); then
		die "$codename lists $query in more than one component (${found[*]}); one package name belongs in one component, so repair that first"
	fi
	queries[${found[0]}]="${queries[${found[0]}]:-}$query"$'\n'
done

# Components in configured order, then the component's packages sorted, so
# that the plan reads the same on every run.
changed=()
for c in "${components[@]}"; do
	if [[ -n ${plan[$c]:-} ]]; then
		changed+=("$c")
	fi
done
for c in "${changed[@]}"; do
	plan[$c]=$(printf '%s' "${plan[$c]}" | LC_ALL=C sort -u)
	while read -r sname sversion sarch; do
		log "withdraw $codename $c $sname $sversion $sarch"
	done <<<"${plan[$c]}"
done

if ((dry_run)); then
	log "dry run: nothing changed"
	exit 0
fi

# --- apply ---------------------------------------------------------------------

if [[ -n $batch ]]; then
	# The batch name, without a .txt suffix, names the snapshots, so that the
	# publication of a batch is found by its file.
	label=withdraw-${batch%.txt}
else
	label=withdraw-$name-$version${arch:+-$arch}
fi

# print_set prints a package set from repo_set, and nothing for an empty one.
print_set() { [[ -z $1 ]] || printf '%s\n' "$1"; }

commits=() snapshots=()
for c in "${changed[@]}"; do
	repo=$(repo_name "$codename" "$c")
	before=${sets[$c]}
	mapfile -t c_queries < <(printf '%s' "${queries[$c]}" | LC_ALL=C sort -u)
	log "removing ${#c_queries[@]} request(s) from $repo"
	aptly_ repo remove "$repo" "${c_queries[@]}" >&2
	after=$(repo_set "$repo")
	removed=$(LC_ALL=C comm -23 <(print_set "$before") <(print_set "$after"))
	# The repository must lose exactly the plan, no more and no less. This
	# runs before any snapshot is created or saved, so a refusal changes
	# nothing that a later run would publish.
	if [[ $removed != "${plan[$c]}" ]]; then
		die "$repo removed something else than the plan; nothing was published (removed: ${removed:-nothing}; plan: ${plan[$c]//$'\n'/, })"
	fi
	snapshot=$(new_snapshot_name "$codename" "$c" "$label")
	aptly_ snapshot create "$snapshot" from repo "$repo" >/dev/null
	commits+=("$codename/$c=$snapshot")
	snapshots+=("$snapshot")
done
# A configured component the codename does not publish yet, empty, with the
# same label, and then one publication for every changed component: one
# signed Release.
others=$(missing_component_snapshots "$codename" "$label" "${changed[@]}")
if [[ -n $others ]]; then
	mapfile -t others_list <<<"$others"
	commits+=("${others_list[@]}")
fi
commit_publications "${commits[@]}"
verify_published "$codename"
# The bucket's own indexes: what clients read must not list a withdrawn row.
for c in "${changed[@]}"; do
	still=$(bucket_set "$codename" "$c")
	while read -r sname sversion sarch; do
		if grep -qxF -- "$sname $sversion $sarch" <<<"$still"; then
			die "$codename still lists $sname $sversion $sarch in $c after the publication"
		fi
	done <<<"${plan[$c]}"
done
# The snapshots of the changed components only, in configured order.
printf '%s %s\n' "$codename" "${snapshots[*]}"
