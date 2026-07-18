# Inferlens — the harness shape lands first. Stubs exit 0 with TODO; real work lands per rung.
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help bootstrap format lint test bench

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

bootstrap: ## Wire git hooks; fetch pinned models + verify checksums (rung 04); resolve the LiteRT xcframework (rung 09)
	@git rev-parse --git-dir >/dev/null 2>&1 && git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks" || true
	@echo "TODO(rung 04/09): fetch checksum-pinned models into Vendor/ and resolve the binaryTarget. See docs/research/MODEL_PROVENANCE.md."

format: ## Run swiftformat
	@echo "TODO(rung 01+): swiftformat . --config .swiftformat"

lint: ## Run swiftlint
	@echo "TODO(rung 01+): swiftlint lint --config .swiftlint.yml"

test: ## Build + run the test suite (run 'make bootstrap' first)
	@echo "TODO(rung 03+): make bootstrap && swift test"

bench: ## On-device latency harness -> JSON (rung 27)
	@echo "TODO(rung 27): run on-device benchmark; emit device/iOS/thermal/run-count/warm-up JSON."
