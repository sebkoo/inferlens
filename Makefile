# Inferlens — build, test, and lint the local SPM workspace.
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help bootstrap lint test test-clean anchor-check media-check prose-lint

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  %-14s %s\n", $$1, $$2}'

bootstrap: ## Fetch checksum-pinned models (the LiteRT xcframework is an SPM binaryTarget, resolved at build)
	@bash scripts/fetch-models.sh
	@echo "litert: TensorFlowLiteC is a checksum-pinned SPM binaryTarget (ADR-0002); SPM fetches + verifies it at build — no bootstrap step. Re-vendor a version bump with scripts/vendor-litert.sh."

lint: ## Run swiftformat --lint and swiftlint
	@command -v swiftformat >/dev/null 2>&1 || { echo "swiftformat not found — install with: brew install swiftformat"; exit 2; }
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not found — install with: brew install swiftlint"; exit 2; }
	swiftformat --lint . && swiftlint lint

test: ## Build + run the test suite on the iOS simulator
	@bash scripts/test-clean.sh

# A fresh -derivedDataPath every run, so xcodebuild cannot report a stale result out of a reused
# DerivedData. The path is printed. Simulator suite only; device latency is measured by the bench.
test-clean: ## Build+test on the iOS sim with a fresh -derivedDataPath per run (no stale-artifact reuse)
	@bash scripts/test-clean.sh

# A broken in-page anchor does not 404: GitHub returns 200 and scrolls nowhere. CI calls each script
# directly for its 0/1/2 exit contract; make collapses any recipe failure to 2.
anchor-check: ## Check every in-page Markdown anchor resolves to a unique heading (slug-derived)
	@bash scripts/anchor-check.sh

media-check: ## Check docs/media ceilings, orphans and alt text
	@bash scripts/media-check.sh

prose-lint: ## Check README length, badge count and banned vocabulary in the docs
	@bash scripts/prose-lint.sh
