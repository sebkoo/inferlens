# Inferlens — the harness shape lands first. Stubs exit 0 with TODO; real work lands per rung.
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help bootstrap format lint test bench claims-audit readme-sync land

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  %-14s %s\n", $$1, $$2}'

bootstrap: ## Wire git hooks; fetch checksum-pinned models (the LiteRT xcframework is an SPM binaryTarget, resolved at build)
	@git rev-parse --git-dir >/dev/null 2>&1 && git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks" || true
	@bash scripts/fetch-models.sh
	@echo "litert: TensorFlowLiteC is a checksum-pinned SPM binaryTarget (ADR-0002); SPM fetches + verifies it at build — no bootstrap step. Re-vendor a version bump with scripts/vendor-litert.sh."

format: ## Run swiftformat
	@echo "TODO: swiftformat . --config .swiftformat"

lint: ## Run swiftlint
	@echo "TODO: swiftlint lint --config .swiftlint.yml"

test: ## Build + run the test suite on the iOS simulator (wired at the 'wire make test' rung)
	@echo "TODO (wire-make-test rung): xcodebuild test -destination 'generic/platform=iOS Simulator'"

bench: ## On-device latency harness -> JSON (the on-device bench rung)
	@echo "TODO (on-device bench rung): run on-device benchmark; emit device/iOS/thermal/run-count/warm-up JSON."

# Per-rung claims audit (docs/ROADMAP.md "Harness backlog"): a tree grep misses two of the three
# surfaces rung 12 got burned by — a claim in a commit MESSAGE and a DEAD-SHA orphaned on origin.
# CLAIM='<regex>' adds this rung's own subject-claim to the built-in forbidden list.
claims-audit: ## Sweep tree + unpushed messages + dead-origin shas for a stale claim (CLAIM='<regex>' optional)
	@bash scripts/claims-audit.sh "$(CLAIM)"

# The rungs badge is DERIVED, never typed. N and D use ONE counting rule (rung-00 counts on
# both sides): N = number of rung-* tags, D = number of rung lines in ROADMAP.md. Computed in
# one place so the two axes can never diverge (the 4/32-off-by-one bug).
readme-sync: ## Rewrite the README rungs badge from git tags + ROADMAP (derived, idempotent)
	@N=$$(git tag -l 'rung-*' | wc -l | tr -d ' '); \
	D=$$(grep -c '^[0-9][0-9] ' docs/ROADMAP.md); \
	sed -i '' -E "s|badge/rungs-[0-9]+%2F[0-9]+-|badge/rungs-$${N}%2F$${D}-|" README.md; \
	echo "badge synced: rungs $$N/$$D  (N=$$N rung-* tags, D=$$D rung lines, same rule)"

# Land a rung: DECLARE it in the tag map, LOCALLY. Commit the rung first, then:
#   make land RUNG=NN
# The badge self-counts this rung, so the tag is created BEFORE readme-sync (to make N right);
# the amend that folds the badge in rewrites the SHA, so the tag is force-moved onto the final
# commit and self-checked (rung-NN == HEAD). NO push here — push branch and tag together,
# atomically, as the separate final step:  git push --atomic origin main rung-NN
land: ## Land the current rung LOCALLY: tag rung-NN on HEAD + fold the derived badge in (RUNG=NN)
	@test -n "$(RUNG)" || { echo "usage: make land RUNG=NN"; exit 1; }
	git tag "rung-$(RUNG)" HEAD
	@$(MAKE) --no-print-directory readme-sync
	git add README.md
	git commit --amend --no-edit
	git tag -f "rung-$(RUNG)" HEAD
	@test "$$(git rev-parse rung-$(RUNG))" = "$$(git rev-parse HEAD)" || { echo "ERROR: rung-$(RUNG) != HEAD"; exit 1; }
	@echo "landed rung $(RUNG) LOCALLY: tag == HEAD, badge folded. Push atomically: git push --atomic origin main rung-$(RUNG)"
