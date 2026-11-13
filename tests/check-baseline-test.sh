#!/usr/bin/env bash
# Negative tests for tests/check-baseline.sh: each case copies the working tree
# to a temporary directory, applies 1 mutation, and requires the check to fail
# with a known message. One case runs the check on an unmutated copy and
# requires exit 0. The repository is never touched; every temporary directory
# goes away on exit.
set -euo pipefail

ROOT=$(realpath "$(cd "$(dirname "$0")/.." && pwd)")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The harness copies the tree into its work directory, so a work directory
# inside the repository would copy itself and recurse. Refuse it at once.
work=$(realpath "$work")
if [[ $work == "$ROOT" || $work == "$ROOT"/* ]]; then
	printf 'not ok - the work directory %s is inside the repository %s\n' "$work" "$ROOT" >&2
	rm -rf "$work"
	exit 1
fi

cases=0
failures=0

copy_tree() { # copy_tree DIR: a copy of the working tree without .git
	mkdir -p "$1"
	(cd "$ROOT" && tar --exclude=./.git -cf - .) | tar -xf - -C "$1"
}

changed() { # changed ORIG COPY REL: succeeds when the copy differs at REL
	local orig=$1 copy=$2 rel=$3
	if [[ -L $orig/$rel || -L $copy/$rel ]]; then
		if [[ $(readlink -- "$orig/$rel") != "$(readlink -- "$copy/$rel")" ]]; then
			return 0
		fi
		return 1
	fi
	if [[ ! -e $orig/$rel || ! -e $copy/$rel ]]; then
		return 0
	fi
	if cmp -s -- "$orig/$rel" "$copy/$rel"; then
		return 1
	fi
	return 0
}

run_case() { # run_case CASE [EXPECTED]: a case name and a needed stderr line
	local id=$1 want=${2-} dir=$work/case-$1 orig=$work/orig-$1 err status
	cases=$((cases + 1))
	copy_tree "$orig"
	mkdir -p "$dir"
	cp -a "$orig/." "$dir"
	if [[ -n $want ]]; then
		if ! "mut_$id" "$dir" "$orig"; then
			printf 'not ok %d - %s: the mutation did not change the tree\n' "$cases" "$id"
			failures=$((failures + 1))
			return 0
		fi
	fi
	if err=$("$dir/tests/check-baseline.sh" 2>&1 >/dev/null); then
		status=0
	else
		status=$?
	fi
	if [[ -z $want ]]; then
		if ((status != 0)); then
			printf 'not ok %d - %s: the check failed on an unmutated tree\n' "$cases" "$id"
			printf '  %s\n' "${err//$'\n'/$'\n'  }"
			failures=$((failures + 1))
			return 0
		fi
		printf 'ok %d - %s\n' "$cases" "$id"
		return 0
	fi
	if ((status == 0)); then
		printf 'not ok %d - %s: the check exited 0\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if [[ $err != *"$want"* ]]; then
		printf 'not ok %d - %s: stderr does not hold "%s"\n' "$cases" "$id" "$want"
		printf '  %s\n' "${err//$'\n'/$'\n'  }"
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok %d - %s\n' "$cases" "$id"
}

run_ok_case() { # run_ok_case CASE: a case that mutates the tree and must pass
	local id=$1 dir=$work/ok-$1 orig=$work/orig-ok-$1 err
	cases=$((cases + 1))
	copy_tree "$orig"
	mkdir -p "$dir"
	cp -a "$orig/." "$dir"
	if ! "mut_$id" "$dir" "$orig"; then
		printf 'not ok %d - %s: the mutation did not change the tree\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if err=$("$dir/tests/check-baseline.sh" 2>&1 >/dev/null); then
		printf 'ok %d - %s\n' "$cases" "$id"
		return 0
	fi
	printf 'not ok %d - %s: the check failed on the mutated tree\n' "$cases" "$id"
	printf '  %s\n' "${err//$'\n'/$'\n'  }"
	failures=$((failures + 1))
}

# B1: the instruction-file symlinks.
mut_b1_remove_gemini() {
	rm -f "$1/GEMINI.md"
	changed "$2" "$1" GEMINI.md
}

mut_b1_absolute_cursorrules() {
	rm -f "$1/.cursorrules"
	ln -s "$1/AGENTS.md" "$1/.cursorrules"
	changed "$2" "$1" .cursorrules
}

mut_b1_regular_claude() {
	rm -f "$1/CLAUDE.md"
	printf 'not a symlink\n' >"$1/CLAUDE.md"
	changed "$2" "$1" CLAUDE.md
}

# B2: the corrections inbox. Each case writes 1 file into
# .memory/corrections/ (or changes the folder), and the expected message names
# the file, so a case fails only for its own reason.
b2_record() { # b2_record DATE EVIDENCE: a canonical record text
	printf '{\n  "date": "%s",\n  "scope": "s",\n  "correction": "c",\n  "evidence": "%s",\n  "promoted_to": ""\n}\n' "$1" "$2"
}

mut_b2_old_file() {
	printf '%s\n' '{"date": "2026-11-06", "scope": "s", "correction": "c", "evidence": "e", "promoted_to": ""}' \
		>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_missing_folder() {
	rm -rf "$1/.memory/corrections"
	changed "$2" "$1" .memory/corrections
}

mut_b2_folder_symlink() {
	mv "$1/.memory/corrections" "$1/.memory/elsewhere"
	ln -s elsewhere "$1/.memory/corrections"
	changed "$2" "$1" .memory/corrections
}

mut_b2_bad_name() {
	b2_record 2026-11-06 e >"$1/.memory/corrections/2026-11-06-Bad_Name.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-Bad_Name.json
}

mut_b2_long_slug() {
	local name
	name=2026-11-06-$(printf 'a%.0s' {1..61}).json
	b2_record 2026-11-06 e >"$1/.memory/corrections/$name"
	changed "$2" "$1" ".memory/corrections/$name"
}

mut_b2_name_date() {
	b2_record 2026-11-06 e >"$1/.memory/corrections/2026-11-07-test-name-date.json"
	changed "$2" "$1" .memory/corrections/2026-11-07-test-name-date.json
}

# The same record written compactly on 1 line.
mut_b2_not_canonical() {
	printf '%s\n' '{"date":"2026-11-06","scope":"s","correction":"c","evidence":"e","promoted_to":""}' \
		>"$1/.memory/corrections/2026-11-06-test-compact.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-compact.json
}

mut_b2_invalid_json() {
	printf '%s' '{"date": "2026-11-06", "scope": "s"' >"$1/.memory/corrections/2026-11-06-test-invalid-json.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-invalid-json.json
}

mut_b2_invalid_utf8() {
	b2_record 2026-11-06 $'\xff' >"$1/.memory/corrections/2026-11-06-test-invalid-utf8.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-invalid-utf8.json
}

mut_b2_duplicate_key() {
	printf '{\n  "date": "2026-11-06",\n  "scope": "s",\n  "correction": "c",\n  "evidence": "e",\n  "promoted_to": "",\n  "scope": "s"\n}\n' \
		>"$1/.memory/corrections/2026-11-06-test-duplicate-key.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-duplicate-key.json
}

mut_b2_missing_key() {
	printf '{\n  "date": "2026-11-06",\n  "scope": "s",\n  "correction": "c",\n  "evidence": "e"\n}\n' \
		>"$1/.memory/corrections/2026-11-06-test-missing-key.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-missing-key.json
}

mut_b2_unknown_key() {
	printf '{\n  "date": "2026-11-06",\n  "scope": "s",\n  "correction": "c",\n  "evidence": "e",\n  "promoted_to": "",\n  "extra": "x"\n}\n' \
		>"$1/.memory/corrections/2026-11-06-test-unknown-key.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-unknown-key.json
}

mut_b2_not_object() {
	printf '%s\n' '[1]' >"$1/.memory/corrections/2026-11-06-test-not-object.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-not-object.json
}

mut_b2_non_string_value() {
	printf '{\n  "date": "2026-11-06",\n  "scope": "s",\n  "correction": "c",\n  "evidence": "e",\n  "promoted_to": 1\n}\n' \
		>"$1/.memory/corrections/2026-11-06-test-non-string.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-non-string.json
}

mut_b2_invalid_date() {
	b2_record 2026-02-30 e >"$1/.memory/corrections/2026-02-30-test-invalid-date.json"
	changed "$2" "$1" .memory/corrections/2026-02-30-test-invalid-date.json
}

mut_b2_bad_date_format() {
	b2_record 2026-1-05 e >"$1/.memory/corrections/2026-11-06-test-date-format.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-date-format.json
}

mut_b2_empty_evidence() {
	b2_record 2026-11-06 '  ' >"$1/.memory/corrections/2026-11-06-test-empty-evidence.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-empty-evidence.json
}

# A record whose evidence is only a byte-order mark: JavaScript trims it away.
mut_b2_bom_evidence() {
	b2_record 2026-11-06 $'\xef\xbb\xbf' >"$1/.memory/corrections/2026-11-06-test-bom-evidence.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-bom-evidence.json
}

mut_b2_subfolder() {
	mkdir "$1/.memory/corrections/2026-11-06-test-folder.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-folder.json
}

mut_b2_record_symlink() {
	local first
	first=$(cd "$1/.memory/corrections" && find . -maxdepth 1 -name '*.json' -printf '%f\n' | sort | head -n 1)
	[[ -n $first ]] || return 1
	ln -s "$first" "$1/.memory/corrections/2026-11-06-test-link.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-link.json
}

mut_b2_gitkeep_not_empty() {
	printf 'x\n' >"$1/.memory/corrections/.gitkeep"
	changed "$2" "$1" .memory/corrections/.gitkeep
}

# A folder with only an empty .gitkeep holds 0 records and passes.
mut_b2_only_gitkeep_ok() {
	rm -f "$1"/.memory/corrections/*.json
	: >"$1/.memory/corrections/.gitkeep"
	changed "$2" "$1" .memory/corrections/.gitkeep
}

# Control characters, non-ASCII text and a raw U+2028 in the form that
# JSON.stringify writes: the check must find it canonical.
mut_b2_unicode_record_ok() {
	b2_record 2026-11-06 $'tab\\t nl\\n ctl\\u0001 del\x7f quote\\" e\xcc\x81 \xe2\x80\xa8 \xf0\x9f\x98\x80' \
		>"$1/.memory/corrections/2026-11-06-test-unicode.json"
	changed "$2" "$1" .memory/corrections/2026-11-06-test-unicode.json
}

# B3: the docs shape.
mut_b3_no_org_adrs() {
	rm -f "$1/docs/org-adrs.md"
	changed "$2" "$1" docs/org-adrs.md
}

mut_b3_no_plans_template() {
	rm -f "$1/docs/plans/TEMPLATE.md"
	changed "$2" "$1" docs/plans/TEMPLATE.md
}

# B4: the make gate and the tool pins.
mut_b4_ci_without_verify() {
	sed -i 's/^ci: verify/ci:/' "$1/Makefile"
	changed "$2" "$1" Makefile
}

mut_b4_no_mise_lock() {
	rm -f "$1/mise.lock"
	changed "$2" "$1" mise.lock
}

# B5: pinned, least-privilege workflows.
mut_b5_unpinned_uses() {
	sed -i 's|@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1|@v4|' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

mut_b5_no_persist_credentials() {
	sed -i '/persist-credentials: false/d' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# A checkout that is not the first key of its list item: the step starts with
# `- name:` and the `uses:` line comes next.
mut_b5_name_first_checkout() {
	printf 'name: fixture\n\non:\n  workflow_dispatch:\n\npermissions: {}\n\ndefaults:\n  run:\n    shell: bash\n\njobs:\n  fixture:\n    runs-on: ubuntu-24.04\n    steps:\n      - name: Checkout\n        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' \
		>"$1/.github/workflows/fixture.yml"
	changed "$2" "$1" .github/workflows/fixture.yml
}

# A step written as a bare dash: YAML allows `-` alone, with the keys on the
# lines below it.
mut_b5_bare_dash_checkout() {
	printf 'name: fixture\n\non:\n  workflow_dispatch:\n\npermissions: {}\n\ndefaults:\n  run:\n    shell: bash\n\njobs:\n  fixture:\n    runs-on: ubuntu-24.04\n    steps:\n      -\n        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' \
		>"$1/.github/workflows/fixture.yml"
	changed "$2" "$1" .github/workflows/fixture.yml
}

# 2 adjacent steps: the second checkout has no persist-credentials, so the
# report names the second step's line, not the first.
mut_b5_second_step_missing_persist() {
	printf 'name: fixture\n\non:\n  workflow_dispatch:\n\npermissions: {}\n\ndefaults:\n  run:\n    shell: bash\n\njobs:\n  fixture:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n        with:\n          persist-credentials: false\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' \
		>"$1/.github/workflows/fixture.yml"
	changed "$2" "$1" .github/workflows/fixture.yml
}

# The reverse: the first checkout has none, so the report names the first step.
mut_b5_first_step_missing_persist() {
	printf 'name: fixture\n\non:\n  workflow_dispatch:\n\npermissions: {}\n\ndefaults:\n  run:\n    shell: bash\n\njobs:\n  fixture:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n        with:\n          persist-credentials: false\n' \
		>"$1/.github/workflows/fixture.yml"
	changed "$2" "$1" .github/workflows/fixture.yml
}

mut_b5_permissions_write_all() {
	sed -i 's/^permissions: {}$/permissions: write-all/' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

mut_b5_permissions_write_scope() {
	sed -i 's/^  contents: read$/  contents: write/' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# B6: the risk paths and their caller.
mut_b6_no_risk_json() {
	rm -f "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

mut_b6_no_scripts_glob() {
	jq '.paths |= map(select(.glob != "scripts/**"))' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# The list in schema version 1: version 2 is the contract (core ADR-0078).
mut_b6_list_v1() {
	jq '.schema_version = 1 | del(.default_level) | .paths |= map(del(.level))' \
		"$1/.github/risk-paths.json" >"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# An entry with no level, in an otherwise valid version 2 list.
mut_b6_missing_level() {
	jq '(.paths[] | select(.glob == "scripts/**")) |= del(.level)' \
		"$1/.github/risk-paths.json" >"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# A default level outside L1 to L4.
mut_b6_bad_default_level() {
	jq '.default_level = "L5"' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

mut_b6_default_level_newline() { # a trailing LF is not part of the level value
	jq '.default_level = "L3\n"' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

mut_b6_entry_level_newline() { # a trailing LF is not part of the level value
	jq '.paths[0].level = "L2\n"' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# Rule C: the caller needs a glob that matches it, not just the list.
mut_b6_no_caller_glob() {
	jq '.paths |= map(select(.glob != ".github/workflows/**"))' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# Rule C: the list needs a glob that matches it (its own entry).
mut_b6_no_self_entry() {
	jq '.paths |= map(select(.glob != ".github/risk-paths.json"))' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# Rule C: the glob that matches the list itself must be L1 or L2.
mut_b6_self_glob_l3() {
	jq '(.paths[] | select(.glob == ".github/risk-paths.json")).level = "L3"' \
		"$1/.github/risk-paths.json" >"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# Rule C: the glob that matches the caller workflow must be L1 or L2.
mut_b6_caller_glob_l3() {
	jq '(.paths[] | select(.glob == ".github/workflows/**")).level = "L3"' \
		"$1/.github/risk-paths.json" >"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# B6 caller: the caller workflow has 1 allowed shape, so each case changes 1
# part of the shipped file. The pin is read from that file, so a core pin update
# does not disarm a case.
caller_pin() { # caller_pin DIR: the 40-hex core commit in the copied caller
	sed -nE 's|^    uses: frostyard/core/\.github/workflows/pr-triage\.yml@([0-9a-f]{40}).*|\1|p' \
		"$1/.github/workflows/risk-paths.yml"
}

# The pin under another job name: the job key itself is part of the shape.
mut_b6_caller_other_job() {
	sed -i 's/^  pr-triage:$/  other:/' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# The older core risk-paths caller at the same 40-character SHA.
mut_b6_caller_wrong_workflow() {
	sed -i 's|pr-triage\.yml@|risk-paths.yml@|' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# A short SHA: the B5 pin scan reports it before B6 reads the body.
mut_b6_caller_short_sha() {
	local sha
	sha=$(caller_pin "$1")
	sed -i "s|@$sha|@${sha:0:7}|" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# The unpinned ref: also the B5 pin scan.
mut_b6_caller_main() {
	local sha
	sha=$(caller_pin "$1")
	sed -i "s|@$sha|@main|" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# `labeled` is what re-runs the job when a label changes.
mut_b6_caller_no_labeled() {
	sed -i 's/, labeled\]/]/' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# A commented-out permission is not a permission; the line itself must be there.
mut_b6_caller_commented_permission() {
	sed -i 's/^      pull-requests: write$/      # pull-requests: write/' \
		"$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# The job holds exactly 2 permissions.
mut_b6_caller_extra_permission() {
	sed -i '/^      contents: read$/a\      actions: read' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# No merge_group trigger: it cannot run from a merge queue.
mut_b6_caller_merge_group() {
	sed -i '/^    types: \[opened/a\  merge_group:' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# The job holds no other key.
mut_b6_caller_extra_line() {
	sed -i '/^  pr-triage:$/a\    name: triage' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# Valid variants: another 40-character SHA, another trailing comment, and
# comment lines with a blank line above the body.
mut_b6_caller_other_sha_comment_ok() {
	local sha
	sha=$(caller_pin "$1")
	sed -i "s|@$sha # .*|@0000000000000000000000000000000000000000 # frostyard/core, 2026-11-10|" \
		"$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

mut_b6_caller_leading_comments_ok() {
	printf '# a note about this caller\n\n# and a second note\n' |
		cat - "$1/.github/workflows/risk-paths.yml" >"$1/.github/workflows/risk-paths.yml.new"
	mv "$1/.github/workflows/risk-paths.yml.new" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# YAML reads a bare CR, NEL, LS and PS as line breaks, so a key can hide in the
# same LF line. Any of them fails before the text check reads a line.
mut_b6_caller_cr_in_pin_comment() {
	awk '/^    uses:/ { printf "%s\r    if: false\n", $0; next } { print }' \
		"$1/.github/workflows/risk-paths.yml" >"$1/.github/workflows/risk-paths.yml.new"
	mv "$1/.github/workflows/risk-paths.yml.new" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

mut_b6_caller_cr_in_header() {
	printf '# a header note\rname: not the body\n' |
		cat - "$1/.github/workflows/risk-paths.yml" >"$1/.github/workflows/risk-paths.yml.new"
	mv "$1/.github/workflows/risk-paths.yml.new" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

mut_b6_caller_nel_in_pin_comment() {
	awk '/^    uses:/ { printf "%s\302\205    if: false\n", $0; next } { print }' \
		"$1/.github/workflows/risk-paths.yml" >"$1/.github/workflows/risk-paths.yml.new"
	mv "$1/.github/workflows/risk-paths.yml.new" "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# Rule C: each glob that matches the list or the caller is L1 or L2. Each case
# adds 1 more entry next to the valid ones, so the new entry alone decides.
risk_add() { # risk_add DIR ORIG GLOB LEVEL: appends 1 entry to the list
	local dir=$1 orig=$2
	jq --arg g "$3" --arg l "$4" \
		'.paths += [{glob: $g, level: $l, why: "governance: a rule C fixture"}]' \
		"$dir/.github/risk-paths.json" >"$dir/.github/risk-paths.json.new"
	mv "$dir/.github/risk-paths.json.new" "$dir/.github/risk-paths.json"
	changed "$orig" "$dir" .github/risk-paths.json
}

mut_b6_glob_q_caller_l3() { # .github/workflows/risk-paths.ym? matches the caller
	risk_add "$1" "$2" '.github/workflows/risk-paths.ym?' L3
}

mut_b6_glob_deep_list_l3() { # **/.github/risk-paths.json matches the list
	risk_add "$1" "$2" '**/.github/risk-paths.json' L3
}

mut_b6_glob_brace_list_l3() { # 1 brace alternative matches the list
	risk_add "$1" "$2" '.github/{risk-paths.jso?,unused}' L3
}

mut_b6_glob_brace_slash_caller_l3() { # a brace alternative holds a /
	risk_add "$1" "$2" '.github/{workflows/risk-paths.yml,unused}' L3
}

mut_b6_glob_brace_slash_list_l3() { # a brace alternative holds a /
	risk_add "$1" "$2" '{.github/risk-paths.json,unused}' L3
}

# The other direction: core's matchGlob does not match these, so the list is
# valid. A matcher that is too eager fails here.
mut_b6_glob_one_alternative_ok() { # 1 brace alternative is malformed
	risk_add "$1" "$2" '.github/risk-paths{.json}' L3
}

mut_b6_glob_empty_alternative_ok() { # an empty brace alternative is malformed
	risk_add "$1" "$2" '.github/risk-paths{.json,}' L3
}

mut_b6_glob_trailing_star_ok() { # **/ needs a final empty segment
	risk_add "$1" "$2" '**/' L3
}

# B7: the pull request template.
mut_b7_rename_risk_heading() {
	sed -i 's/^## Risk tier$/## Tiers/' "$1/.github/pull_request_template.md"
	changed "$2" "$1" .github/pull_request_template.md
}

# B12: the CI entry.
mut_b12_no_make_ci() {
	sed -i '/^      - run: make ci$/d' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# B13: Dependabot.
mut_b13_no_github_actions() {
	sed -i 's/^  - package-ecosystem: "github-actions"$/  - package-ecosystem: "npm"/' \
		"$1/.github/dependabot.yml"
	changed "$2" "$1" .github/dependabot.yml
}

# B14: the security policy.
mut_b14_no_security_url() {
	sed -i 's|https://github.com/frostyard/apt-publisher/security|https://example.org/security|' \
		"$1/SECURITY.md"
	changed "$2" "$1" SECURITY.md
}

# B15: no CODEOWNERS.
mut_b15_codeowners() {
	printf '* @frostyard/owners\n' >"$1/.github/CODEOWNERS"
	changed "$2" "$1" .github/CODEOWNERS
}

# B16: no leftover agent-framework trees.
mut_b16_planning_tree() {
	mkdir -p "$1/.planning"
	printf 'x\n' >"$1/.planning/x"
	changed "$2" "$1" .planning
}

mut_b16_claude_other_file() {
	mkdir -p "$1/.claude"
	printf '# other\n' >"$1/.claude/other.md"
	changed "$2" "$1" .claude
}

# B17: the README.
mut_b17_duplicate_marker() {
	printf '<!-- readme-kind: packaging -->\n' >>"$1/README.md"
	changed "$2" "$1" README.md
}

mut_b17_long_readme() {
	printf 'word %.0s' {1..1000} >>"$1/README.md"
	printf '\n' >>"$1/README.md"
	changed "$2" "$1" README.md
}

order=(
	unmutated
	b1_remove_gemini
	b1_absolute_cursorrules
	b1_regular_claude
	b2_old_file
	b2_missing_folder
	b2_folder_symlink
	b2_bad_name
	b2_long_slug
	b2_name_date
	b2_not_canonical
	b2_invalid_json
	b2_invalid_utf8
	b2_duplicate_key
	b2_missing_key
	b2_unknown_key
	b2_not_object
	b2_non_string_value
	b2_invalid_date
	b2_bad_date_format
	b2_empty_evidence
	b2_bom_evidence
	b2_subfolder
	b2_record_symlink
	b2_gitkeep_not_empty
	b3_no_org_adrs
	b3_no_plans_template
	b4_ci_without_verify
	b4_no_mise_lock
	b5_unpinned_uses
	b5_no_persist_credentials
	b5_name_first_checkout
	b5_bare_dash_checkout
	b5_second_step_missing_persist
	b5_first_step_missing_persist
	b5_permissions_write_all
	b5_permissions_write_scope
	b6_no_risk_json
	b6_no_self_entry
	b6_no_scripts_glob
	b6_list_v1
	b6_missing_level
	b6_bad_default_level
	b6_self_glob_l3
	b6_caller_glob_l3
	b6_default_level_newline
	b6_entry_level_newline
	b6_no_caller_glob
	b6_glob_q_caller_l3
	b6_glob_deep_list_l3
	b6_glob_brace_list_l3
	b6_glob_brace_slash_caller_l3
	b6_glob_brace_slash_list_l3
	b6_caller_other_job
	b6_caller_wrong_workflow
	b6_caller_short_sha
	b6_caller_main
	b6_caller_no_labeled
	b6_caller_commented_permission
	b6_caller_extra_permission
	b6_caller_merge_group
	b6_caller_extra_line
	b6_caller_cr_in_pin_comment
	b6_caller_cr_in_header
	b6_caller_nel_in_pin_comment
	b7_rename_risk_heading
	b12_no_make_ci
	b13_no_github_actions
	b14_no_security_url
	b15_codeowners
	b16_planning_tree
	b16_claude_other_file
	b17_duplicate_marker
	b17_long_readme
)

# Cases that mutate the tree and must pass.
ok_order=(
	b2_only_gitkeep_ok
	b2_unicode_record_ok
	b6_caller_other_sha_comment_ok
	b6_caller_leading_comments_ok
	b6_glob_one_alternative_ok
	b6_glob_empty_alternative_ok
	b6_glob_trailing_star_ok
)

declare -A expected=(
	[b1_remove_gemini]='GEMINI.md must be a symlink to AGENTS.md'
	[b1_absolute_cursorrules]='.cursorrules must be a relative symlink'
	[b1_regular_claude]='CLAUDE.md must be a symlink to AGENTS.md'
	[b2_old_file]='.memory/corrections.jsonl is retired; add a file under .memory/corrections/'
	[b2_missing_folder]='.memory/corrections: folder is missing'
	[b2_folder_symlink]='.memory/corrections: symbolic link, not followed'
	[b2_bad_name]='.memory/corrections/2026-11-06-Bad_Name.json: bad file name'
	[b2_long_slug]='-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json: slug longer than 60 characters'
	[b2_name_date]='.memory/corrections/2026-11-07-test-name-date.json: name date 2026-11-07 does not equal date 2026-11-06'
	[b2_not_canonical]='.memory/corrections/2026-11-06-test-compact.json: not in canonical form'
	[b2_invalid_json]='.memory/corrections/2026-11-06-test-invalid-json.json: invalid JSON'
	[b2_invalid_utf8]='.memory/corrections/2026-11-06-test-invalid-utf8.json: invalid UTF-8'
	[b2_duplicate_key]='.memory/corrections/2026-11-06-test-duplicate-key.json: duplicate key(s): scope'
	[b2_missing_key]='.memory/corrections/2026-11-06-test-missing-key.json: missing key(s): promoted_to'
	[b2_unknown_key]='.memory/corrections/2026-11-06-test-unknown-key.json: unknown key(s): extra'
	[b2_not_object]='.memory/corrections/2026-11-06-test-not-object.json: not a JSON object'
	[b2_non_string_value]='.memory/corrections/2026-11-06-test-non-string.json: value for promoted_to is not a string'
	[b2_invalid_date]='.memory/corrections/2026-02-30-test-invalid-date.json: invalid date: 2026-02-30'
	[b2_bad_date_format]='.memory/corrections/2026-11-06-test-date-format.json: invalid date: 2026-1-05'
	[b2_empty_evidence]='.memory/corrections/2026-11-06-test-empty-evidence.json: evidence is empty'
	[b2_bom_evidence]='.memory/corrections/2026-11-06-test-bom-evidence.json: evidence is empty'
	[b2_subfolder]='.memory/corrections/2026-11-06-test-folder.json: not a regular file'
	[b2_record_symlink]='.memory/corrections/2026-11-06-test-link.json: symbolic link, not followed'
	[b2_gitkeep_not_empty]='.memory/corrections/.gitkeep: .gitkeep is not empty'
	[b3_no_org_adrs]='docs/org-adrs.md is missing'
	[b3_no_plans_template]='docs/plans/TEMPLATE.md is missing'
	[b4_ci_without_verify]='the Makefile ci: rule must list verify'
	[b4_no_mise_lock]='mise.lock is missing'
	[b5_unpinned_uses]='uses is not pinned to a 40-character commit SHA'
	[b5_no_persist_credentials]='the checkout step does not set persist-credentials: false'
	[b5_name_first_checkout]='.github/workflows/fixture.yml:16: the checkout step does not set persist-credentials: false'
	[b5_bare_dash_checkout]='.github/workflows/fixture.yml:16: the checkout step does not set persist-credentials: false'
	[b5_second_step_missing_persist]='.github/workflows/fixture.yml:19: the checkout step does not set persist-credentials: false'
	[b5_first_step_missing_persist]='.github/workflows/fixture.yml:16: the checkout step does not set persist-credentials: false'
	[b5_permissions_write_all]='the permissions line must be permissions: {} or a block of read scopes'
	[b5_permissions_write_scope]='the permissions block holds a scope that is not read'
	[b6_no_self_entry]='rule C: no glob in the list matches .github/risk-paths.json'
	[b6_no_risk_json]='.github/risk-paths.json is missing'
	[b6_no_scripts_glob]='does not list the glob scripts/**'
	[b6_list_v1]='.github/risk-paths.json must set schema_version 2'
	[b6_missing_level]='scripts/**: level must be L1, L2, L3 or L4'
	[b6_bad_default_level]='.github/risk-paths.json must set default_level to L1, L2, L3 or L4'
	[b6_self_glob_l3]='rule C: the glob .github/risk-paths.json matches .github/risk-paths.json'
	[b6_default_level_newline]='.github/risk-paths.json must set default_level to L1, L2, L3 or L4'
	[b6_entry_level_newline]="level must be L1, L2, L3 or L4, not \"L2\n\""
	[b6_no_caller_glob]='rule C: no glob in the list matches .github/workflows/risk-paths.yml'
	[b6_caller_glob_l3]='rule C: the glob .github/workflows/** matches .github/workflows/risk-paths.yml'
	[b6_glob_q_caller_l3]='rule C: the glob .github/workflows/risk-paths.ym? matches .github/workflows/risk-paths.yml'
	[b6_glob_deep_list_l3]='rule C: the glob **/.github/risk-paths.json matches .github/risk-paths.json'
	[b6_glob_brace_list_l3]='rule C: the glob .github/{risk-paths.jso?,unused} matches .github/risk-paths.json'
	[b6_glob_brace_slash_caller_l3]='rule C: the glob .github/{workflows/risk-paths.yml,unused} matches .github/workflows/risk-paths.yml'
	[b6_glob_brace_slash_list_l3]='rule C: the glob {.github/risk-paths.json,unused} matches .github/risk-paths.json'
	[b6_caller_other_job]="expected '  pr-triage:', found '  other:'"
	[b6_caller_short_sha]='uses is not pinned to a 40-character commit SHA'
	[b6_caller_no_labeled]="expected '    types: [opened, synchronize, reopened, edited, labeled]'"
	[b6_caller_commented_permission]="expected '      pull-requests: write', found '      # pull-requests: write'"
	[b6_caller_extra_permission]="expected '      pull-requests: write', found '      actions: read'"
	[b6_caller_merge_group]="expected '<blank>', found '  merge_group:'"
	[b6_caller_cr_in_pin_comment]='holds a CR (U+000D)'
	[b6_caller_cr_in_header]='holds a CR (U+000D)'
	[b6_caller_nel_in_pin_comment]='holds a NEL (U+0085)'
	[b6_caller_extra_line]="expected '    permissions:', found '    name: triage'"
	[b6_caller_main]='uses is not pinned to a 40-character commit SHA'
	[b6_caller_wrong_workflow]="expected '    uses: frostyard/core/.github/workflows/pr-triage.yml@<40 hex>'"
	[b7_rename_risk_heading]='has no heading that names the risk tier'
	[b12_no_make_ci]='has no run: make ci step'
	[b13_no_github_actions]='has no github-actions entry'
	[b14_no_security_url]='does not link https://github.com/frostyard/apt-publisher/security'
	[b15_codeowners]='.github/CODEOWNERS must not exist'
	[b16_planning_tree]='.planning must not exist'
	[b16_claude_other_file]='.claude/ holds other.md'
	[b17_duplicate_marker]='must have exactly 1 line'
	[b17_long_readme]='the limit is 1000'
)

for id in "${order[@]}"; do
	run_case "$id" "${expected[$id]-}"
done

for id in "${ok_order[@]}"; do
	run_ok_case "$id"
done

# The guard against a work directory inside the repository, tested on a
# scratch copy so the real repository is never the tree under test. The inner
# run must stop before it copies anything. Its tar is a stub that records a
# sentinel and fails, so a missing guard fails at once and cannot recurse.
run_tmpdir_guard() {
	local id=tmpdir_inside_repository dir=$work/guard-tree out=$work/guard.out status
	local stub=$work/guard-bin sentinel=$work/guard-tar-ran
	cases=$((cases + 1))
	copy_tree "$dir"
	mkdir -p "$dir/var/tmp" "$stub"
	printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$sentinel" >"$stub/tar"
	chmod +x "$stub/tar"
	if (cd "$dir" && PATH=$stub:$PATH TMPDIR=$dir/var/tmp "$dir/tests/check-baseline-test.sh") >"$out" 2>&1; then
		status=0
	else
		status=$?
	fi
	if ((status == 0)); then
		printf 'not ok %d - %s: the inner harness exited 0\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if ! grep -q 'is inside the repository' "$out"; then
		printf 'not ok %d - %s: no message about the work directory\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if [[ -e $sentinel ]]; then
		printf 'not ok %d - %s: the inner harness started a copy\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if [[ -n $(ls -A "$dir/var/tmp") ]]; then
		printf 'not ok %d - %s: %s is left behind\n' "$cases" "$id" "$(ls -A "$dir/var/tmp")"
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok %d - %s\n' "$cases" "$id"
}

# Direct cases for the glob matcher of tests/check-baseline.sh (a port of
# core's matchGlob). They load only the block between its "risk-path glob"
# markers, so they test the function the check runs, not a copy. Each row is
# glob, path, and 0 (match) or 1 (no match), as core's matchGlob answers.
run_matcher_cases() {
	local block glob path want got
	block=$(sed -n '/^# ---- risk-path glob (start) ----$/,/^# ---- risk-path glob (end) ----$/p' \
		"$ROOT/tests/check-baseline.sh")
	local -a rows=(
		$'a\n' a 1
		a $'a\n' 1
		$'a\n' $'a\n' 0
		$'.github/risk-paths.json\n' .github/risk-paths.json 1
		'a?b' $'a\xf0\x9f\x98\x80b' 0
		'a??b' $'a\xf0\x9f\x98\x80b' 1
		'**/x' /x 0
		'a/**' a 0
		'{a,b}/c' b/c 0
		'*a' '*ba' 0
	)
	cases=$((cases + 1))
	if [[ -z $block ]]; then
		printf 'not ok %d - matcher_direct_cases: no risk-path glob block in the check\n' "$cases"
		failures=$((failures + 1))
		return 0
	fi
	local i bad=''
	for ((i = 0; i < ${#rows[@]}; i += 3)); do
		glob=${rows[i]} path=${rows[i + 1]} want=${rows[i + 2]}
		if (eval "$block"; risk_path_matches "$glob" "$path"); then got=0; else got=1; fi
		[[ $got == "$want" ]] || bad+="${bad:+; }$(printf '%q vs %q gave %s, want %s' "$glob" "$path" "$got" "$want")"
	done
	if [[ -n $bad ]]; then
		printf 'not ok %d - matcher_direct_cases: %s\n' "$cases" "$bad"
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok %d - matcher_direct_cases (%d rows)\n' "$cases" $((${#rows[@]} / 3))
}

run_matcher_cases

run_tmpdir_guard

printf '1..%d\n' "$cases"
if ((failures > 0)); then
	printf '%d case(s) failed\n' "$failures" >&2
	exit 1
fi
