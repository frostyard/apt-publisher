#!/usr/bin/env bash
# Import the legacy repogen suite (dists/stable) into a codename, in two
# runs:
#
#   1. --download-only verifies InRelease against keys/frostyard.gpg, each
#      Packages index against the signed Release, and each .deb against its
#      Packages SHA256 and control fields. It writes manifest.tsv and prints
#      the manifest's SHA256 for review. Nothing else changes.
#   2. --expect-manifest SHA256 repeats the verification, refuses if the
#      manifest differs from the reviewed one, adds exactly the manifest's
#      files to the codename's repository, and publishes a snapshot.
#
# Rerunning both steps later picks up releases that only reached stable:
# identical files are no-ops; changed bytes under a published version are
# refused. The legacy suite and its pool are only read, never modified.
#
# The legacy suite has one component, main, and it is imported into the main
# component. A codename that also publishes image gets a snapshot of it too,
# empty when it has no packages, also when the codename is already published
# without it (core ADR-0059: `publish switch` cannot add a component).
#
# Prints the manifest SHA256 (step 1) or "CODENAME SNAPSHOT" (step 2).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: import-stable.sh --codename CODENAME (--download-only | --expect-manifest SHA256)
                        [--base-url URL] [--suite SUITE] [--work DIR]

  --codename         codename to import into, e.g. trixie
  --download-only    download and verify, print the manifest SHA256, then stop
  --expect-manifest  publish, if the verified manifest has this SHA256
  --base-url         legacy repository root; default https://repository.frostyard.org
  --suite            legacy suite; default stable
  --work             download directory, reused across attempts; default $APTLY_ROOT/import
EOF
	exit 2
}

codename='' base_url=https://repository.frostyard.org suite=stable work='' download_only=0 expect=
while (($#)); do
	case $1 in
	--codename) codename=${2:?} && shift ;;
	--base-url) base_url=${2:?} && shift ;;
	--suite) suite=${2:?} && shift ;;
	--work) work=${2:?} && shift ;;
	--download-only) download_only=1 ;;
	--expect-manifest) expect=${2:?} && shift ;;
	*) usage ;;
	esac
	shift
done
[[ -n $codename ]] || usage
((download_only)) || [[ -n $expect ]] || usage
require curl gpgv dpkg-deb sha256sum
archs=$(codename_field "$codename" 3) || die "unknown codename $codename"
work=${work:-$APTLY_ROOT/import}
base_url=${base_url%/}
mkdir -p "$work/pool"

fetch() { curl -fsSL --retry 3 -o "$2" "$base_url/$1"; }

dists="dists/$suite"
fetch "$dists/InRelease" "$work/InRelease"
gpgv --keyring "$APT_KEYRING" --output "$work/Release" "$work/InRelease" 2>"$work/gpgv.log" ||
	die "$dists/InRelease is not signed by $APT_KEYRING: $(cat "$work/gpgv.log")"
log "verified $dists/InRelease"

: >"$work/stanzas.tsv"
read -ra suite_archs <<<"$(sed -n 's/^Architectures: //p' "$work/Release")"
for arch in "${suite_archs[@]}"; do
	in_csv "$arch" "$archs" || die "$suite publishes $arch, which $codename does not"
	path="main/binary-$arch/Packages"
	want=$(release_sha256 "$work/Release" "$path") || die "$dists/Release does not list $path"
	fetch "$dists/$path" "$work/Packages-$arch"
	[[ $(sha256sum <"$work/Packages-$arch" | cut -d' ' -f1) == "$want" ]] ||
		die "$dists/$path does not match its Release hash"
	stanzas_tsv "$work/Packages-$arch" | cut -f1-6 >>"$work/stanzas.tsv"
done

# arch:all packages can appear in more than one index; one Filename must
# always mean one set of bytes.
LC_ALL=C sort -u "$work/stanzas.tsv" >"$work/manifest.tsv"
dup=$(cut -f1 "$work/manifest.tsv" | uniq -d | head -1)
[[ -z $dup ]] || die "$dup is listed with different metadata in two indexes"

total=$(wc -l <"$work/manifest.tsv")
n=0
while IFS=$'\t' read -r filename sha256 size name version arch; do
	n=$((n + 1))
	[[ $filename =~ ^pool/[A-Za-z0-9._+~/-]+\.deb$ && $filename != *..* ]] ||
		die "refusing unexpected Filename $filename"
	dest="$work/$filename"
	if [[ ! -f $dest ]] || [[ $(sha256sum <"$dest" | cut -d' ' -f1) != "$sha256" ]]; then
		log "[$n/$total] $filename"
		mkdir -p "$(dirname "$dest")"
		fetch "$filename" "$dest.part"
		mv -- "$dest.part" "$dest"
	fi
	[[ $(stat -c %s "$dest") == "$size" ]] || die "$filename has the wrong size"
	[[ $(sha256sum <"$dest" | cut -d' ' -f1) == "$sha256" ]] || die "$filename has the wrong SHA256"
	[[ $(dpkg-deb -f "$dest" Package Version Architecture) == "Package: $name"$'\n'"Version: $version"$'\n'"Architecture: $arch" ]] ||
		die "$filename control fields do not match its Packages entry"
done <"$work/manifest.tsv"
manifest_sha=$(sha256sum <"$work/manifest.tsv" | cut -d' ' -f1)
log "verified $total packages from $suite; manifest $work/manifest.tsv has SHA256 $manifest_sha"

if ((download_only)); then
	printf '%s\n' "$manifest_sha"
	exit 0
fi
[[ $manifest_sha == "$expect" ]] ||
	die "the verified manifest ($manifest_sha) is not the reviewed one ($expect); review it again"

aptly_init
reconcile_state "$codename"
mapfile -t names < <(cut -f4 "$work/manifest.tsv" | LC_ALL=C sort -u)
one_component_rule "$codename" main "${names[@]}"
repo=$(ensure_repo "$codename" main)
# Only the verified files: the work directory may hold leftovers.
mapfile -t paths < <(awk -F'\t' -v w="$work" '{ print w "/" $1 }' "$work/manifest.tsv")
aptly_ repo add "$repo" "${paths[@]}" >&2
snapshot=$(new_snapshot_name "$codename" main "import-$suite")
aptly_ snapshot create "$snapshot" from repo "$repo" >/dev/null
commits=("$codename/main=$snapshot")
others=$(missing_component_snapshots "$codename" "import-$suite" main)
if [[ -n $others ]]; then
	mapfile -t others_list <<<"$others"
	commits+=("${others_list[@]}")
fi
commit_publications "${commits[@]}"
verify_published "$codename" --deep
printf '%s %s\n' "$codename" "$snapshot"
