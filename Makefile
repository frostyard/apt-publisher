.PHONY: help verify check ci lint test

help: ## Show targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*## " } { printf "  %-8s %s\n", $$1, $$2 }'

verify: lint test ## Credential-free, non-mutating gate

check: verify ## Developer gate (nothing to format)

ci: verify ## CI gate

lint: ## shellcheck, actionlint, configuration checks, and the baseline with its negative tests
	shellcheck scripts/*.sh tests/*.sh
	actionlint
	tests/check-config.sh
	tests/check-baseline.sh
	tests/check-baseline-test.sh

test: ## End-to-end test against a local S3 server
	timeout 600 tests/run.sh
