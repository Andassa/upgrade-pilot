.DEFAULT_GOAL := help
.PHONY: help deps data build test golden integration verify fmt fmt-check \
        analyze security docs demo release-dry-run clean

DART_SOURCES := lib bin tool test/unit test/golden test/security \
                test/architecture test/integration test/support
COVERAGE_SUITES := test/unit test/golden test/security test/architecture
BINARY := build/upgrade-pilot

help: ## List the targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deps: ## Fetch dependencies (pubspec.lock is versioned)
	dart pub get

data: ## Embed data/kb.json and data/rules.json, refresh checksums
	dart run tool/embed_data.dart

build: deps ## Compile the native binary into build/
	@mkdir -p build
	dart compile exe bin/upgrade_pilot.dart -o $(BINARY)

fmt: ## Format the sources
	dart format $(DART_SOURCES)

fmt-check:
	dart format --output=none --set-exit-if-changed $(DART_SOURCES)

analyze:
	dart analyze --fatal-infos

test: deps ## Unit, golden, security and architecture tests + coverage gates
	rm -rf coverage
	dart test --coverage=coverage $(COVERAGE_SUITES)
	dart run coverage:format_coverage --lcov --in=coverage \
		--out=coverage/lcov.info --report-on=lib --check-ignore
	dart run tool/coverage_check.dart coverage/lcov.info

golden: ## Rewrite terminal golden files after an intended UI change
	UPDATE_GOLDENS=1 dart test test/golden

integration: deps ## Real runs on test/fixtures (needs Flutter + Android SDK)
	dart test -P integration test/integration

security: ## Secret scan (gitleaks when installed) and dependency check
	@if command -v gitleaks >/dev/null 2>&1; then \
		gitleaks detect --no-banner --redact --source .; \
	else \
		echo "gitleaks not installed: using tool/secret_scan.dart"; \
		dart run tool/secret_scan.dart; \
	fi
	dart pub outdated --no-dev-dependencies --up-to-date --no-transitive

verify: deps fmt-check ## Everything CI checks: format, data, analysis, tests, coverage, secrets
	dart run tool/embed_data.dart --check
	$(MAKE) analyze
	$(MAKE) test
	$(MAKE) security

docs: deps ## API documentation into build/doc
	dart doc --output build/doc

demo: build ## Record a real run on the legacy fixture (see doc/demo.sh)
	bash doc/demo.sh

release-dry-run: deps build ## Check publication and the binary
	dart run tool/publish_check.dart
	$(BINARY) --version

clean: ## Remove build outputs and coverage (caches: upgrade-pilot clean)
	rm -rf build coverage .dart_tool/test
