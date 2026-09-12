# Wave - per-app volume and output routing for macOS
#
# Everything is driven from SwiftPM, so there is no project file to keep in
# sync. `make verify` is the one command that proves the build, the tests and
# the audio chain in that order.

CONFIGURATION ?= release
BUILD_DIR     ?= build
APP           := $(BUILD_DIR)/Wave.app
SPIKE         := $(APP)/Contents/MacOS/wave-spike

.DEFAULT_GOAL := app

.PHONY: app
app: ## Build and sign Wave.app
	@CONFIGURATION=$(CONFIGURATION) BUILD_DIR=$(BUILD_DIR) ./Scripts/build-app.sh

.PHONY: debug
debug: ## Build a debug Wave.app
	@$(MAKE) app CONFIGURATION=debug

.PHONY: test
test: ## Run the unit tests
	swift test

.PHONY: strict
strict: ## Build with warnings escalated to errors
	swift build -c $(CONFIGURATION) \
		-Xswiftc -warnings-as-errors \
		-Xcc -Werror

.PHONY: run
run: app ## Build and launch Wave
	open $(APP)

.PHONY: list
list: app ## Show the audio processes and output devices Wave can see
	@$(SPIKE) list

.PHONY: permission
permission: app ## Report the system audio recording permission state
	@$(SPIKE) permission

.PHONY: spike
spike: app ## Prove the capture -> gain -> output chain. APP=<name> [DEVICE=<name>] [SECONDS=n]
	@if [ -z "$(APP_NAME)" ]; then \
		echo "usage: make spike APP_NAME=\"Music\" [DEVICE=\"AirPods\"] [SECONDS=30]"; \
		echo; echo "Available applications:"; $(SPIKE) list; exit 2; \
	fi
	@$(SPIKE) route --app "$(APP_NAME)" \
		$(if $(DEVICE),--device "$(DEVICE)",) \
		--seconds $(or $(SECONDS),30)

.PHONY: verify
verify: ## Full check: strict build, tests, then the audio spike instructions
	@echo "==> Strict build"
	@$(MAKE) --no-print-directory strict
	@echo
	@echo "==> Tests"
	@swift test
	@echo
	@echo "==> App bundle"
	@$(MAKE) --no-print-directory app
	@echo
	@echo "==> Permission"
	@$(SPIKE) permission
	@echo
	@echo "Build and tests passed. The audio chain needs a human ear:"
	@echo "  1. Start playback in an app (Music, Spotify, a browser tab)."
	@echo "  2. make spike APP_NAME=\"<that app>\""
	@echo "  3. Confirm the audio gets quieter and louder as the fader sweeps,"
	@echo "     that it comes out of the device the spike names, and that it"
	@echo "     is NOT also coming out of your normal output."
	@echo "  4. Ctrl-C and confirm normal playback returns."
	@echo
	@echo "The full checklist is in docs/ACCEPTANCE.md."

.PHONY: clean
clean: ## Remove build products
	swift package clean
	rm -rf $(BUILD_DIR) .build

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
