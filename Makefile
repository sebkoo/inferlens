# Inferlens — build, test, and lint the local SPM workspace.
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help bootstrap lint test claims-audit test-clean anchor-check

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  %-14s %s\n", $$1, $$2}'

bootstrap: ## Wire git hooks; fetch checksum-pinned models (the LiteRT xcframework is an SPM binaryTarget, resolved at build)
	@git rev-parse --git-dir >/dev/null 2>&1 && git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks" || true
	@bash scripts/fetch-models.sh
	@echo "litert: TensorFlowLiteC is a checksum-pinned SPM binaryTarget (ADR-0002); SPM fetches + verifies it at build — no bootstrap step. Re-vendor a version bump with scripts/vendor-litert.sh."

lint: ## Run swiftformat --lint and swiftlint
	@command -v swiftformat >/dev/null 2>&1 || { echo "swiftformat not found — install with: brew install swiftformat"; exit 2; }
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not found — install with: brew install swiftlint"; exit 2; }
	swiftformat --lint . && swiftlint lint

test: ## Build + run the test suite on the iOS simulator
	@bash scripts/test-clean.sh

# Per-rung claims audit (docs/ROADMAP.md "Harness backlog"): a tree grep misses two of the three
# surfaces rung 12 got burned by — a claim in a commit MESSAGE and a DEAD-SHA orphaned on origin.
# CLAIM='<regex>' adds this rung's own subject-claim to the built-in forbidden list.
claims-audit: ## Sweep tree + unpushed messages + dead-origin shas for a stale claim (CLAIM='<regex>' optional)
	@bash scripts/claims-audit.sh "$(CLAIM)"

# test-clean uses a FRESH -derivedDataPath every run (a fresh mktemp dir), so xcodebuild cannot report a
# stale result out of a reused DerivedData — it did, twice this session (a spurious TEST SUCCEEDED). The
# path is printed. Simulator suite only; device-only latency is the bench rung.
test-clean: ## Build+test on the iOS sim with a fresh -derivedDataPath per run (no stale-artifact reuse)
	@bash scripts/test-clean.sh

# anchor-check: every in-page (#anchor) link in the Markdown resolves to a real, unique heading — the
# anchor half of the cross-document-pointer gap (a broken anchor 200s and scrolls nowhere). Slugs are
# derived GitHub's way. CI calls the script directly for the 0/1/2 contract; make collapses failures to 2.
anchor-check: ## Check every in-page Markdown anchor resolves to a unique heading (slug-derived)
	@bash scripts/anchor-check.sh
