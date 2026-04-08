PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin
LIBDIR  = $(PREFIX)/lib/claude-cost
DATADIR = $(HOME)/.local/share/claude-cost
CONFDIR = $(XDG_CONFIG_HOME)
ifeq ($(CONFDIR),)
CONFDIR = $(HOME)/.config
endif
CONFDIR := $(CONFDIR)/claude-cost

UNAME_S := $(shell uname -s)
PLIST_LABEL  = com.claude-cost.collect
PLIST_PATH   = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
SYSTEMD_DIR  = $(HOME)/.config/systemd/user

# Read config for schedule values (with defaults)
SCHEDULE_HOUR   ?= $(shell [ -f "$(CONFDIR)/config" ] && . "$(CONFDIR)/config" 2>/dev/null; echo $${SCHEDULE_HOUR:-2})
SCHEDULE_MINUTE ?= $(shell [ -f "$(CONFDIR)/config" ] && . "$(CONFDIR)/config" 2>/dev/null; echo $${SCHEDULE_MINUTE:-0})

.PHONY: install uninstall reload-schedule lint test help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

install: ## Install claude-cost scripts and schedule
	@echo "Installing claude-cost..."
	@mkdir -p $(BINDIR) $(LIBDIR) $(DATADIR)/logs
	install -m 755 bin/claude-cost-collect $(BINDIR)/
	install -m 755 bin/claude-cost-report  $(BINDIR)/
	install -m 644 lib/claude-cost-common.sh $(LIBDIR)/
	@# Config (never overwrite existing)
	@mkdir -p $(CONFDIR)
	@if [ ! -f "$(CONFDIR)/config" ]; then \
		install -m 644 claude-cost.conf.example $(CONFDIR)/config; \
		echo "  Created config: $(CONFDIR)/config"; \
	else \
		echo "  Config exists:  $(CONFDIR)/config (not overwritten)"; \
	fi
	@# Schedule
ifeq ($(UNAME_S),Darwin)
	@sed \
		-e 's|%%COLLECT_SCRIPT%%|$(BINDIR)/claude-cost-collect|g' \
		-e 's|%%HOUR%%|$(SCHEDULE_HOUR)|g' \
		-e 's|%%MINUTE%%|$(SCHEDULE_MINUTE)|g' \
		-e 's|%%LOG_DIR%%|$(DATADIR)/logs|g' \
		share/com.claude-cost.collect.plist.in > $(PLIST_PATH)
	@launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@launchctl load $(PLIST_PATH)
	@echo "  Scheduled: launchd daily at $(SCHEDULE_HOUR):$(shell printf '%02d' $(SCHEDULE_MINUTE))"
else
	@mkdir -p $(SYSTEMD_DIR)
	@sed \
		-e 's|%%COLLECT_SCRIPT%%|$(BINDIR)/claude-cost-collect|g' \
		share/claude-cost-collect.service.in > $(SYSTEMD_DIR)/claude-cost-collect.service
	@sed \
		-e 's|%%HOUR%%|$(SCHEDULE_HOUR)|g' \
		-e 's|%%MINUTE%%|$(SCHEDULE_MINUTE)|g' \
		share/claude-cost-collect.timer.in > $(SYSTEMD_DIR)/claude-cost-collect.timer
	@systemctl --user daemon-reload
	@systemctl --user enable --now claude-cost-collect.timer
	@echo "  Scheduled: systemd timer daily at $(SCHEDULE_HOUR):$(shell printf '%02d' $(SCHEDULE_MINUTE))"
endif
	@echo ""
	@echo "Done! Run 'claude-cost-collect' for immediate first collection."

uninstall: ## Remove scripts and schedule (preserves data and config)
	@echo "Uninstalling claude-cost..."
ifeq ($(UNAME_S),Darwin)
	@launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@rm -f $(PLIST_PATH)
else
	@systemctl --user disable --now claude-cost-collect.timer 2>/dev/null || true
	@rm -f $(SYSTEMD_DIR)/claude-cost-collect.service $(SYSTEMD_DIR)/claude-cost-collect.timer
	@systemctl --user daemon-reload 2>/dev/null || true
endif
	rm -f $(BINDIR)/claude-cost-collect $(BINDIR)/claude-cost-report
	rm -rf $(LIBDIR)
	@echo ""
	@echo "Done. Config and data preserved at:"
	@echo "  Config: $(CONFDIR)/config"
	@echo "  Data:   $(DATADIR)/usage.db"

reload-schedule: ## Regenerate and reload the schedule from config
ifeq ($(UNAME_S),Darwin)
	@sed \
		-e 's|%%COLLECT_SCRIPT%%|$(BINDIR)/claude-cost-collect|g' \
		-e 's|%%HOUR%%|$(SCHEDULE_HOUR)|g' \
		-e 's|%%MINUTE%%|$(SCHEDULE_MINUTE)|g' \
		-e 's|%%LOG_DIR%%|$(DATADIR)/logs|g' \
		share/com.claude-cost.collect.plist.in > $(PLIST_PATH)
	@launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@launchctl load $(PLIST_PATH)
	@echo "Reloaded: launchd daily at $(SCHEDULE_HOUR):$(shell printf '%02d' $(SCHEDULE_MINUTE))"
else
	@sed \
		-e 's|%%HOUR%%|$(SCHEDULE_HOUR)|g' \
		-e 's|%%MINUTE%%|$(SCHEDULE_MINUTE)|g' \
		share/claude-cost-collect.timer.in > $(SYSTEMD_DIR)/claude-cost-collect.timer
	@systemctl --user daemon-reload
	@systemctl --user restart claude-cost-collect.timer
	@echo "Reloaded: systemd timer daily at $(SCHEDULE_HOUR):$(shell printf '%02d' $(SCHEDULE_MINUTE))"
endif

lint: ## Run shellcheck on all scripts
	shellcheck --severity=warning bin/claude-cost-collect bin/claude-cost-report lib/claude-cost-common.sh lib/fetchers/claude.sh lib/fetchers/codex.sh

test: ## Run smoke tests
	bash tests/smoke.sh
