#!/usr/bin/env bash
# End-to-end test of the publisher against a local S3 server (rclone serve
# s3) and a throwaway signing key. Each script runs with a fresh APTLY_ROOT,
# as on a new CI runner, so aptly state survives only through the state
# bucket. apt itself consumes the published result.
#
# KEEP_TMP=1 keeps the work directory for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in aptly rclone jq gpg gpgv gpgconf dpkg-deb apt-get apt-cache curl python3 sha256sum gzip; do
	command -v "$tool" >/dev/null || {
		echo "not ok - $tool is required" >&2
		exit 1
	}
done

tmp=$(mktemp -d)
server_pid=''
cleanup() {
	[[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
	GNUPGHOME=$tmp/gnupg gpgconf --kill gpg-agent 2>/dev/null || true
	if [[ -n ${KEEP_TMP:-} ]]; then
		echo "kept $tmp" >&2
	else
		rm -rf -- "$tmp"
	fi
}
trap cleanup EXIT

n=0
ok() {
	n=$((n + 1))
	printf 'ok %d - %s\n' "$n" "$1"
}
not_ok() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
check() {
	local desc=$1
	shift
	"$@" || not_ok "$desc"
	ok "$desc"
}
# must_fail DESC PATTERN CMD... expects CMD to fail with PATTERN on stderr.
must_fail() {
	local desc=$1 pattern=$2
	shift 2
	if "$@" >"$tmp/out" 2>"$tmp/err"; then
		not_ok "$desc (unexpectedly succeeded)"
	fi
	grep -q -- "$pattern" "$tmp/err" || {
		cat "$tmp/err" >&2
		not_ok "$desc (stderr lacks: $pattern)"
	}
	ok "$desc"
}
# must_pass DESC CMD... runs CMD, keeping stdout in $tmp/out and stderr in
# $tmp/err.
must_pass() {
	local desc=$1
	shift
	"$@" >"$tmp/out" 2>"$tmp/err" || {
		cat "$tmp/err" >&2
		not_ok "$desc"
	}
	ok "$desc"
}

# --- fixtures ---------------------------------------------------------------

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$tmp/s3/frostyardrepo" "$tmp/s3/frostyard-apt-state"
# Keep rclone's default directory cache: with --dir-cache-time 0s, serve s3
# intermittently livelocks on uploads into new nested prefixes. Every change
# in this test goes through the S3 API, so the cache never goes stale.
rclone serve s3 --addr "127.0.0.1:$port" --auth-key testaccesskey,testsecretkey123 \
	"$tmp/s3" >"$tmp/s3.log" 2>&1 &
server_pid=$!
for _ in $(seq 50); do
	curl -s -o /dev/null "http://127.0.0.1:$port/" && break
	sleep 0.1
done

export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
for uid in 'apt-publisher test <test@invalid>' 'someone else <other@invalid>'; do
	gpg -q --batch --passphrase '' --quick-gen-key "$uid" ed25519 sign never 2>/dev/null
done
gpg -q --check-trustdb 2>/dev/null
mapfile -t fprs < <(gpg --list-keys --with-colons | awk -F: '/^fpr/ { print $10 }')
gpg --export "${fprs[0]}" >"$tmp/test-key.gpg"
gpg --export "${fprs[1]}" >"$tmp/other-key.gpg"

cat >"$tmp/producers.tsv" <<'EOF'
frostyard/updex	frostyard-updex	trixie,forky	yes	frostyard/snosi
frostyard/bootc-debian	bootc,libostree-*	trixie,forky	no	-
frostyard/trixie-only	trixie-thing	trixie	no	-
EOF

# Fail instead of hanging if the local server stalls.
export RCLONE_TIMEOUT=30s RCLONE_CONTIMEOUT=10s
: >"$tmp/rclone.conf"
export RCLONE_CONFIG=$tmp/rclone.conf
export R2_ACCESS_KEY_ID=testaccesskey R2_SECRET_ACCESS_KEY=testsecretkey123
export APT_S3_ENDPOINT=http://127.0.0.1:$port APT_RCLONE_PROVIDER=Other
export APT_SIGNING_KEY_FPR=${fprs[0]} APT_KEYRING=$tmp/test-key.gpg
export APT_PRODUCERS_FILE=$tmp/producers.tsv
unset R2_ACCOUNT_ID APTLY_ROOT
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Other RCLONE_CONFIG_R2_ENDPOINT=$APT_S3_ENDPOINT
export RCLONE_CONFIG_R2_ACCESS_KEY_ID=testaccesskey RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=testsecretkey123

# scope NAME isolates a scenario under its own bucket prefix and state path.
# The public URL is the bucket's directory on disk.
scope() {
	export APT_PREFIX=$1 APT_STATE_PATH=$1
	pub=$tmp/s3/frostyardrepo/$1
	export APT_PUBLIC_URL=file://$pub
}
scope debian

# run SCRIPT ARGS... runs a publisher script as a fresh runner.
run() { APTLY_ROOT=$(mktemp -d "$tmp/runner.XXXXXX") "$ROOT/scripts/$1" "${@:2}"; }

# mkdeb DIR NAME VERSION ARCH [CONTENT] builds DIR/NAME_VERSION_ARCH.deb.
mkdeb() {
	local dir=$1 name=$2 version=$3 arch=$4 src
	src=$(mktemp -d "$tmp/build.XXXXXX")
	mkdir -p "$src/DEBIAN" "$src/usr/share/doc/$name" "$dir"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test <test@invalid>\nDescription: test package\n' \
		"$name" "$version" "$arch" >"$src/DEBIAN/control"
	printf '%s\n' "${5:-$name $version $arch}" >"$src/usr/share/doc/$name/content"
	dpkg-deb --root-owner-group -b "$src" "$dir/${name}_${version}_${arch}.deb" >/dev/null
}

# Legacy repogen-shaped suite: dists/stable with binary-all and binary-amd64.
make_legacy() {
	local legacy=$1 deb name arch letter dir rel
	for deb in "$tmp"/legacy-debs/*.deb; do
		name=$(dpkg-deb -f "$deb" Package)
		arch=$(dpkg-deb -f "$deb" Architecture)
		letter=${name:0:1}
		[[ $name == lib* ]] && letter=${name:0:4}
		dir=pool/main/$letter/$name
		mkdir -p "$legacy/$dir" "$legacy/dists/stable/main/binary-$arch"
		cp "$deb" "$legacy/$dir/"
		{
			dpkg-deb -f "$deb"
			printf 'Filename: %s/%s\nSize: %s\nSHA256: %s\n\n' "$dir" "$(basename "$deb")" \
				"$(stat -c %s "$deb")" "$(sha256sum <"$deb" | cut -d' ' -f1)"
		} >>"$legacy/dists/stable/main/binary-$arch/Packages"
	done
	{
		printf 'Origin: Repogen Repository\nLabel: Frostyard Repository\nSuite: stable\nCodename: stable\n'
		printf 'Architectures: all amd64\nComponents: main\nSHA256:\n'
		for rel in main/binary-all/Packages main/binary-amd64/Packages; do
			printf ' %s %s %s\n' "$(sha256sum <"$legacy/dists/stable/$rel" | cut -d' ' -f1)" \
				"$(stat -c %s "$legacy/dists/stable/$rel")" "$rel"
		done
	} >"$legacy/dists/stable/Release"
	gpg -q --batch --yes --local-user "${fprs[0]}" --clearsign \
		-o "$legacy/dists/stable/InRelease" "$legacy/dists/stable/Release"
}

# listed CODENAME NAME VERSION [ARCH]: the published indexes on disk list it.
listed() {
	awk -v n="$2" -v v="$3" -v a="${4:-}" '
		BEGIN { RS = ""; FS = "\n" }
		{
			delete f
			for (i = 1; i <= NF; i++) if (match($i, /^[A-Za-z-]+: /)) f[substr($i, 1, RLENGTH - 2)] = substr($i, RLENGTH + 1)
			if (f["Package"] == n && f["Version"] == v && (a == "" || f["Architecture"] == a)) found = 1
		}
		END { exit !found }' "$pub/dists/$1"/main/binary-*/Packages
}
not_listed() { ! listed "$@"; }

# candidate CODENAME ARCH PACKAGE prints apt's candidate version.
candidate() {
	local d
	d=$(mktemp -d "$tmp/apt.XXXXXX")
	mkdir -p "$d/etc/sources.list.d" "$d/etc/apt.conf.d" "$d/etc/preferences.d" \
		"$d/state/lists/partial" "$d/cache/archives/partial"
	: >"$d/state/status"
	printf 'Types: deb\nURIs: file://%s\nSuites: %s\nComponents: main\nSigned-By: %s\n' \
		"$pub" "$1" "$tmp/test-key.gpg" >"$d/etc/sources.list.d/test.sources"
	local opts=(-o "Dir::Etc=$d/etc" -o Dir::Etc::sourcelist=/dev/null
		-o "Dir::Etc::sourceparts=$d/etc/sources.list.d" -o "Dir::State=$d/state"
		-o "Dir::State::status=$d/state/status" -o "Dir::Cache=$d/cache"
		-o Debug::NoLocking=1 -o "APT::Architecture=$2" -o "APT::Architectures::=$2"
		-o "APT::Sandbox::User=$(id -un)")
	apt-get "${opts[@]}" -q update >"$d/update.log" 2>&1 || {
		cat "$d/update.log" >&2
		return 1
	}
	grep -q '^[WE]:' "$d/update.log" && {
		cat "$d/update.log" >&2
		return 1
	}
	apt-cache "${opts[@]}" policy "$3" | awk '/Candidate:/ { print $2 }'
}
candidate_is() { [[ $(candidate "$1" "$2" "$3") == "$4" ]]; }

inrelease() { sha256sum <"$pub/dists/$1/InRelease"; }
pool_file() { find "$pub/pool" -name "$1" | head -1; }
# corrupt PATH replaces a bucket object below the current prefix.
corrupt() { printf 'corrupted bytes\n' | rclone rcat "r2:frostyardrepo/$APT_PREFIX/$1"; }

# A shim on PATH that fails the Nth save of a state path's database.
mkdir -p "$tmp/shim-rclone" "$tmp/shim-gh"
real_rclone=$(command -v rclone)
cat >"$tmp/shim-rclone/rclone" <<EOF
#!/usr/bin/env bash
if [[ \$1 == sync && \${*: -1} == r2:frostyard-apt-state/\$SHIM_STATE_PATH/db ]]; then
	count=\$(( \$(cat "$tmp/shim-rclone/count" 2>/dev/null || echo 0) + 1 ))
	echo "\$count" >"$tmp/shim-rclone/count"
	if [[ \$count == "\$SHIM_FAIL_AT" ]]; then
		echo "shim: simulated failure saving the database" >&2
		exit 1
	fi
fi
exec "$real_rclone" "\$@"
EOF
# gh release view --repo OWNER/REPO --json ... serves $tmp/gh/OWNER_REPO.json.
cat >"$tmp/shim-gh/gh" <<EOF
#!/usr/bin/env bash
[[ \$1 == release && \$2 == view ]] || exit 2
while ((\$#)); do
	[[ \$1 == --repo ]] && repo=\$2
	shift
done
f="$tmp/gh/\${repo//\//_}.json"
[[ -f \$f ]] || { echo "release not found" >&2; exit 1; }
cat "\$f"
EOF
chmod +x "$tmp/shim-rclone/rclone" "$tmp/shim-gh/gh"
mkdir -p "$tmp/gh"

# --- dry run ------------------------------------------------------------------

mkdeb "$tmp/bootc" bootc '1.16.8-1~deb13' amd64
mkdeb "$tmp/bootc" bootc '1.16.8-1~deb14' amd64
must_pass "dry run succeeds" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc" --dry-run
check "dry run routes ~deb13 to trixie" grep -q 'bootc_1.16.8-1~deb13_amd64.deb -> trixie' "$tmp/err"
check "dry run routes ~deb14 to forky" grep -q 'bootc_1.16.8-1~deb14_amd64.deb -> forky' "$tmp/err"
check "dry run touches no state" test -z "$(ls -A "$tmp/s3/frostyard-apt-state")"

# --- import of the legacy suite -----------------------------------------------

mkdeb "$tmp/legacy-debs" frostyard-updex 2.0.0 amd64
mkdeb "$tmp/legacy-debs" frostyard-updex 2.0.1 amd64
mkdeb "$tmp/legacy-debs" docs-thing 1.0 all
mkdeb "$tmp/legacy-debs" libfoo1 1.0-1 amd64
make_legacy "$tmp/legacy"

cp -a "$tmp/legacy" "$tmp/legacy-tampered"
mkdeb "$tmp/evil" frostyard-updex 2.0.1 amd64 'tampered bytes'
cp "$tmp/evil/frostyard-updex_2.0.1_amd64.deb" "$tmp/legacy-tampered/pool/main/f/frostyard-updex/"
must_fail "import rejects a .deb that does not match its index" "wrong" \
	run import-stable.sh --codename trixie --base-url "file://$tmp/legacy-tampered" --download-only
must_fail "import rejects an InRelease signed by another key" "is not signed by" \
	env APT_KEYRING="$tmp/other-key.gpg" "$ROOT/scripts/import-stable.sh" \
	--codename trixie --base-url "file://$tmp/legacy" --work "$tmp/wrong-key" --download-only
must_fail "import requires a reviewed manifest to publish" "usage" \
	run import-stable.sh --codename trixie --base-url "file://$tmp/legacy"

legacy=(--codename trixie --base-url "file://$tmp/legacy" --work "$tmp/import-work")
must_pass "review run verifies the legacy suite" run import-stable.sh "${legacy[@]}" --download-only
manifest=$(cat "$tmp/out")
check "review run prints the manifest SHA256" grep -Eqx '[0-9a-f]{64}' <<<"$manifest"
check "review run touches no state" test -z "$(ls -A "$tmp/s3/frostyard-apt-state")"

must_fail "import refuses a manifest other than the reviewed one" "not the reviewed one" \
	run import-stable.sh "${legacy[@]}" --expect-manifest "$(printf '0%.0s' {1..64})"

# A leftover in the reused work directory is not in the signed indexes.
mkdeb "$tmp/import-work/pool/leftover" smuggled 6.6.6 amd64
must_pass "import publishes the reviewed manifest" run import-stable.sh "${legacy[@]}" --expect-manifest "$manifest"
import_snapshot=$(cut -d' ' -f2 "$tmp/out")
check "import publishes every legacy version" listed trixie frostyard-updex 2.0.0
check "import publishes the newest legacy version" listed trixie frostyard-updex 2.0.1
check "import keeps arch:all packages" listed trixie docs-thing 1.0
check "import ignores files outside the manifest" not_listed trixie smuggled 6.6.6
check "published suite is by-hash" grep -qx 'Acquire-By-Hash: yes' "$pub/dists/trixie/Release"
check "apt reads the imported suite" candidate_is trixie amd64 frostyard-updex 2.0.1

# --- producer publication -------------------------------------------------------

mkdeb "$tmp/updex" frostyard-updex 2.0.2 amd64
mkdeb "$tmp/updex" frostyard-updex 2.0.2 arm64
must_pass "publish updex 2.0.2" run publish.sh --producer frostyard/updex --debs "$tmp/updex" \
	--label updex-v2.0.2 --report "$tmp/report.tsv"
cp "$tmp/out" "$tmp/updex.out"
check "publish reports both codenames" test "$(cut -d' ' -f1 "$tmp/updex.out" | sort | tr '\n' ' ')" = 'forky trixie '
check "publish writes a report for the canary" grep -qxP 'forky\tfrostyard-updex\t2.0.2\tarm64' "$tmp/report.tsv"
check "trixie gains 2.0.2 and keeps the import" listed trixie frostyard-updex 2.0.2
check "trixie still lists 2.0.1" listed trixie frostyard-updex 2.0.1
check "forky is first-published with 2.0.2" listed forky frostyard-updex 2.0.2
check "forky does not inherit trixie's imports" not_listed forky frostyard-updex 2.0.1
check "apt on trixie/amd64 sees 2.0.2" candidate_is trixie amd64 frostyard-updex 2.0.2
check "apt on forky/arm64 sees 2.0.2" candidate_is forky arm64 frostyard-updex 2.0.2
check "both codenames share one pool file" \
	test "$(find "$pub/pool" -name 'frostyard-updex_2.0.2_amd64.deb' | wc -l)" = 1
must_pass "the canary installs the report through the public URL" run apt-canary.sh --report "$tmp/report.tsv"

must_pass "publish bootc" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc"
check "trixie gets the ~deb13 build" listed trixie bootc '1.16.8-1~deb13'
check "trixie does not get the ~deb14 build" not_listed trixie bootc '1.16.8-1~deb14'
check "forky gets the ~deb14 build" listed forky bootc '1.16.8-1~deb14'
check "apt on forky prefers ~deb14" candidate_is forky amd64 bootc '1.16.8-1~deb14'

# --- refusals leave the published suite untouched ---------------------------------

before=$(inrelease trixie)

mkdeb "$tmp/hijack" bootc 9.9 amd64
must_fail "a producer cannot publish another producer's package" "may not publish package bootc" \
	run publish.sh --producer frostyard/updex --debs "$tmp/hijack"

mkdeb "$tmp/conflict" frostyard-updex 2.0.2 amd64 'different bytes, same version'
must_fail "republishing a version with different bytes fails" "failed to be added" \
	run publish.sh --producer frostyard/updex --debs "$tmp/conflict"

mkdeb "$tmp/forky-build" bootc '1.17.0-1~deb14' amd64
must_fail "a ~deb14 build cannot go to trixie" "not a target" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/forky-build" --codenames trixie

mkdeb "$tmp/trixie-only" trixie-thing 1.0 amd64
must_fail "a producer cannot publish outside its codenames" "may not publish to forky" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only" --codenames forky

must_fail "an unregistered producer is refused" "not a registered producer" \
	run publish.sh --producer frostyard/stranger --debs "$tmp/updex"

mkdeb "$tmp/i386" frostyard-updex 2.0.3 i386
must_fail "an unpublished architecture is refused" "architecture i386" \
	run publish.sh --producer frostyard/updex --debs "$tmp/i386"

rclone move --quiet r2:frostyard-apt-state/debian r2:frostyard-apt-state/aside
mkdeb "$tmp/updex-next" frostyard-updex 2.0.3 amd64
must_fail "lost state never overwrites a published suite" "does not match aptly's database" \
	run publish.sh --producer frostyard/updex --debs "$tmp/updex-next"
rclone move --quiet r2:frostyard-apt-state/aside r2:frostyard-apt-state/debian

check "refusals left trixie unchanged" test "$(inrelease trixie)" = "$before"
must_pass "publishing resumes once state is back" run publish.sh --producer frostyard/updex --debs "$tmp/updex-next"
check "trixie lists the resumed publication" listed trixie frostyard-updex 2.0.3

# --- a publish that dies before becoming visible --------------------------------------

before=$(inrelease trixie)
mkdeb "$tmp/updex-signfail" frostyard-updex 2.0.4 amd64
must_fail "a signing failure aborts the publish" "unable to" \
	env APT_SIGNING_KEY_FPR=0000000000000000000000000000000000000000 \
	APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/updex-signfail" --codenames trixie
check "the failed publish left InRelease unchanged" test "$(inrelease trixie)" = "$before"
mkdeb "$tmp/bootc-next" bootc '1.16.9-1~deb13' amd64
must_pass "the next producer's run drops the stale pending marker" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc-next"
check "the next run publishes its own package" listed trixie bootc '1.16.9-1~deb13'
check "the next run also publishes the stranded package" listed trixie frostyard-updex 2.0.4

# --- point-in-time rollback -------------------------------------------------------------

must_pass "roll trixie back to the import" run switch.sh --codename trixie --snapshot "$import_snapshot"
check "rollback restores the imported versions" candidate_is trixie amd64 frostyard-updex 2.0.1
check "rollback unpublishes later packages" not_listed trixie bootc '1.16.9-1~deb13'
check "rollback deletes no pool files" test -n "$(pool_file 'frostyard-updex_2.0.3_amd64.deb')"
check "forky is untouched by a trixie rollback" listed forky frostyard-updex 2.0.2

must_pass "publish an unrelated package after the rollback" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only"
check "the unrelated package is published" listed trixie trixie-thing 1.0
check "the rollback survives an unrelated publication" not_listed trixie frostyard-updex 2.0.3
check "rolled-back producers stay rolled back" not_listed trixie bootc '1.16.9-1~deb13'

must_pass "republishing a release rolls it forward" \
	run publish.sh --producer frostyard/updex --debs "$tmp/updex" --codenames trixie
check "the rolled-forward release is listed" listed trixie frostyard-updex 2.0.2 arm64
must_fail "switch refuses another codename's snapshot" "was not created for trixie" \
	run switch.sh --codename trixie --snapshot "$(grep '^forky ' "$tmp/updex.out" | cut -d' ' -f2)"

# --- withdraw ------------------------------------------------------------------------

must_pass "withdraw updex 2.0.2 from trixie" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 2.0.2
check "trixie no longer lists 2.0.2" not_listed trixie frostyard-updex 2.0.2
check "withdraw keeps every other package" listed trixie trixie-thing 1.0
check "withdraw is per codename" listed forky frostyard-updex 2.0.2
check "withdraw deletes no pool files" test -n "$(pool_file 'frostyard-updex_2.0.2_amd64.deb')"

mkdeb "$tmp/trixie-only-next" trixie-thing 1.1 amd64
must_pass "publish an unrelated package after the withdrawal" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-next"
trixie_snapshot=$(cut -d' ' -f2 "$tmp/out")
check "the withdrawal survives an unrelated publication" not_listed trixie frostyard-updex 2.0.2

must_pass "withdraw one architecture" \
	run withdraw.sh --codename forky --package frostyard-updex --version 2.0.2 --arch arm64
check "forky keeps the other architecture" listed forky frostyard-updex 2.0.2 amd64
check "forky drops the withdrawn architecture" not_listed forky frostyard-updex 2.0.2 arm64
must_fail "withdrawing an unlisted version is refused" "has no" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 9.9
must_fail "withdraw rejects a malformed package name" "invalid package name" \
	run withdraw.sh --codename trixie --package 'bad name' --version 1

# --- read-back verification and repair -----------------------------------------------

must_pass "verify accepts the published suite" \
	run verify.sh trixie trixie-thing=1.1 '!frostyard-updex=2.0.2'
must_fail "verify rejects a missing version" "does not list" run verify.sh trixie frostyard-updex=9.9
must_fail "verify rejects a version that should be gone" "still lists" \
	run verify.sh forky '!frostyard-updex=2.0.2'
must_pass "the canary installs from trixie" run apt-canary.sh trixie amd64 trixie-thing=1.1 frostyard-updex=2.0.1

corrupt "$(cd "$pub" && find pool -name 'trixie-thing_1.1_amd64.deb')"
must_pass "metadata-only verify cannot see a corrupted package" run verify.sh trixie
must_fail "verify checks a named package's bytes" "does not match its SHA256" \
	run verify.sh trixie trixie-thing=1.1
must_fail "deep verify finds the corrupted pool file" "MD5 mismatch" run verify.sh trixie --deep
must_fail "the canary refuses the corrupted package" "apt-get download trixie-thing=1.1" \
	run apt-canary.sh trixie amd64 trixie-thing=1.1
must_pass "switch --force repairs the pool file" \
	run switch.sh --codename trixie --snapshot "$trixie_snapshot" --force
must_pass "deep verify passes after the repair" run verify.sh trixie --deep
must_pass "the canary passes after the repair" run apt-canary.sh trixie amd64 trixie-thing=1.1

# Another writer's stanza, appended to the published index.
{
	rclone cat r2:frostyardrepo/debian/dists/trixie/main/binary-amd64/Packages
	printf '\nPackage: injected\nVersion: 1\nArchitecture: amd64\nFilename: pool/main/i/injected/injected_1_amd64.deb\nSHA256: %064d\n\n' 0
} >"$tmp/injected"
rclone rcat r2:frostyardrepo/debian/dists/trixie/main/binary-amd64/Packages <"$tmp/injected"
must_fail "verify rejects an index that does not match Release" "does not match its Release hash" \
	run verify.sh trixie
mkdeb "$tmp/trixie-only-later" trixie-thing 1.2 amd64
must_fail "a tampered index blocks publication" "does not match aptly's database" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-later"
must_pass "switch --force restores the index" \
	run switch.sh --codename trixie --snapshot "$trixie_snapshot" --force
must_pass "publication resumes after the repair" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-later"
check "the resumed publication is listed" listed trixie trixie-thing 1.2

check "state history keeps replaced database files" \
	test -n "$(rclone lsf r2:frostyard-apt-state/debian/history/)"
check "purge covers InRelease" grep -qx "$APT_PUBLIC_URL/dists/trixie/InRelease" \
	<("$ROOT/scripts/purge-cache.sh" --print trixie)

# --- an older database cannot overwrite newer publications -------------------------------

scope stale
mkdeb "$tmp/stale-a" frostyard-updex 2.0.0 amd64
mkdeb "$tmp/stale-b" frostyard-updex 2.9.0 amd64
mkdeb "$tmp/stale-c" bootc '1.0-1~deb13' amd64
must_pass "publish 2.0.0" run publish.sh --producer frostyard/updex --debs "$tmp/stale-a" --codenames trixie
rclone copy --quiet r2:frostyard-apt-state/stale/db r2:frostyard-apt-state/stale-old/db
must_pass "publish 2.9.0" run publish.sh --producer frostyard/updex --debs "$tmp/stale-b" --codenames trixie
rclone copy --quiet r2:frostyard-apt-state/stale/db r2:frostyard-apt-state/stale-new/db
rclone sync --quiet r2:frostyard-apt-state/stale-old/db r2:frostyard-apt-state/stale/db
before=$(inrelease trixie)
must_fail "an older database is refused" "does not match aptly's database" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/stale-c"
check "the refusal keeps 2.9.0 published" listed trixie frostyard-updex 2.9.0
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
rclone sync --quiet r2:frostyard-apt-state/stale-new/db r2:frostyard-apt-state/stale/db
must_pass "the current database publishes" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/stale-c"
check "2.9.0 survives" listed trixie frostyard-updex 2.9.0

# --- a publish that dies after becoming visible is completed --------------------------

scope interrupted
export SHIM_STATE_PATH=interrupted SHIM_FAIL_AT=2
mkdeb "$tmp/int-a" frostyard-updex 2.0.0 amd64
must_fail "a first publication interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/int-a" --codenames trixie
check "the interrupted first publication is visible" listed trixie frostyard-updex 2.0.0
must_pass "retrying converges" run publish.sh --producer frostyard/updex --debs "$tmp/int-a" --codenames trixie
check "the retry completed the interrupted publication" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
must_pass "the completed suite verifies" run verify.sh trixie --deep frostyard-updex=2.0.0

rm -f -- "$tmp/shim-rclone/count"
mkdeb "$tmp/int-b" frostyard-updex 2.0.1 amd64
must_fail "a switch interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/int-b" --codenames trixie
mkdeb "$tmp/int-c" bootc '1.0-1~deb13' amd64
must_pass "another producer's run completes it and publishes" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/int-c"
check "that run reported the completion" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the interrupted release stays published" listed trixie frostyard-updex 2.0.1
check "the other producer's release is published" listed trixie bootc '1.0-1~deb13'

# --- audit of producers' latest releases ------------------------------------------------

scope audit
mkdeb "$tmp/audit-updex" frostyard-updex 3.1.0 amd64
mkdeb "$tmp/audit-bootc" bootc '2.1-1~deb13' amd64
mkdeb "$tmp/audit-thing" trixie-thing 1.0 amd64
must_pass "publish updex for the audit" run publish.sh --producer frostyard/updex --debs "$tmp/audit-updex"
must_pass "publish bootc for the audit" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/audit-bootc"
must_pass "publish trixie-thing for the audit" run publish.sh --producer frostyard/trixie-only --debs "$tmp/audit-thing"
release() { jq -n --arg t "$2" '{tagName: $t, assets: ($ARGS.positional | map({name: .}))}' --args "${@:3}" >"$tmp/gh/$1.json"; }
release frostyard_updex v3.1.0 frostyard-updex_3.1.0_amd64.deb checksums.txt
release frostyard_bootc-debian v2.1 'bootc_2.1-1~deb13_amd64.deb'
release frostyard_trixie-only v1.0 trixie-thing_1.0_amd64.deb
must_pass "the audit passes when every latest release is published" \
	env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh"
release frostyard_updex v3.2.0 frostyard-updex_3.2.0_amd64.deb
if env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit reports an unpublished release (unexpectedly passed)"
fi
check "the audit reports an unpublished release" \
	grep -qx 'MISSING frostyard/updex v3.2.0 frostyard-updex_3.2.0_amd64.deb' "$tmp/out"

# --- secrets check ------------------------------------------------------------

# Cloudflare's API accepts token testcftoken and only zone testzone; gh
# accepts token testdispatch and logs each call to $tmp/dispatches.
mkdir -p "$tmp/shim-check"
cat >"$tmp/shim-check/curl" <<'EOF'
#!/usr/bin/env bash
[[ $* == *'Bearer testcftoken'* ]] || {
	echo '{"success": false, "errors": [{"message": "Authentication error"}]}'
	exit 0
}
case $* in
*/zones/testzone/purge_cache*) echo '{"success": true}' ;;
*/purge_cache*) echo '{"success": false, "errors": [{"message": "Could not route to zone"}]}' ;;
*/user/tokens/verify*) echo '{"success": true, "result": {"status": "active"}}' ;;
*) exit 2 ;;
esac
EOF
cat >"$tmp/shim-check/gh" <<EOF
#!/usr/bin/env bash
[[ \$GH_TOKEN == testdispatch ]] || { echo 'HTTP 401: Bad credentials' >&2; exit 1; }
echo "\$*" >>"$tmp/dispatches"
EOF
chmod +x "$tmp/shim-check/curl" "$tmp/shim-check/gh"
secrets=(PATH="$tmp/shim-check:$PATH" APT_SIGNING_KEY="$(gpg --armor --export-secret-keys "${fprs[0]}")"
	CLOUDFLARE_ZONE=testzone CLOUDFLARE_API_TOKEN=testcftoken GH_TOKEN=testdispatch)
must_pass "the secrets check passes with working secrets" env "${secrets[@]}" "$ROOT/scripts/check-secrets.sh"
check "the secrets check covers the key, both buckets, the zone and snosi" test "$(grep -c '^ok - ' "$tmp/out")" = 5
check "the dispatch check sends no build event" \
	grep -qx 'api --method POST repos/frostyard/snosi/dispatches -f event_type=apt-publisher-token-check' "$tmp/dispatches"
if env "${secrets[@]}" APT_SIGNING_KEY_FPR=0000000000000000000000000000000000000000 \
	APT_STATE_BUCKET=missing-bucket CLOUDFLARE_ZONE=otherzone \
	"$ROOT/scripts/check-secrets.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the secrets check reports every failing secret (unexpectedly passed)"
fi
check "the secrets check reports every failing secret" test "$(grep -c '^FAIL - ' "$tmp/out")" = 3
check "a failing secret does not stop the other checks" grep -qx 'ok - DISPATCH_TOKEN can dispatch to frostyard/snosi' "$tmp/out"

echo "1..$n"
