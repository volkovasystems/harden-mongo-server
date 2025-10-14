# MongoDB Server Hardening Tool - Makefile
# Build, test, and distribution automation

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Project metadata
PROJECT_NAME := harden-mongo-server
PROJECT_VERSION := $(shell sed -n '1p' VERSION 2>/dev/null || echo "0.0.0")
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Directories
SRC_DIR := .
BUILD_DIR := build
DIST_DIR := dist
TEST_DIR := tests
DOCS_DIR := docs
LIB_DIR := lib/harden-mongo-server
EXAMPLES_DIR := examples

# Installation paths
PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
LIBDIR := $(PREFIX)/lib/$(PROJECT_NAME)
SHAREDIR := $(PREFIX)/share/$(PROJECT_NAME)
CONFIGDIR := /etc/$(PROJECT_NAME)

# Colors for output
NO_COLOR := \033[0m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
RED := \033[0;31m

# Helper functions
define print_header
	@echo -e "$(BLUE)================================================$(NO_COLOR)"
	@echo -e "$(BLUE) MongoDB Server Hardening Tool - $(1)$(NO_COLOR)"
	@echo -e "$(BLUE)================================================$(NO_COLOR)"
endef

define print_success
	@echo -e "$(GREEN)✓ $(1)$(NO_COLOR)"
endef

define print_warning
	@echo -e "$(YELLOW)⚠ $(1)$(NO_COLOR)"
endef

define print_error
	@echo -e "$(RED)✗ $(1)$(NO_COLOR)"
endef

# Targets
.PHONY: help build test install uninstall clean lint format check package dev-setup

help: ## Show this help message
	@echo -e "$(BLUE)MongoDB Server Hardening Tool - Build System$(NO_COLOR)"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NO_COLOR) %s\n", $$1, $$2}'
	@echo ""
	@echo "Build variables:"
	@echo "  PREFIX=$(PREFIX)     Installation prefix"
	@echo "  VERSION=$(PROJECT_VERSION)       Project version"

build: ## Build the project
	$(call print_header,Building Project)
	@mkdir -p $(BUILD_DIR)
	@cp harden-mongo-server $(BUILD_DIR)/harden-mongo-server
	@chmod +x $(BUILD_DIR)/harden-mongo-server
	@mkdir -p $(BUILD_DIR)/lib/harden-mongo-server
	@cp -r $(LIB_DIR)/* $(BUILD_DIR)/lib/harden-mongo-server/
	@cp README.md LICENSE $(BUILD_DIR)/
	@cp VERSION $(BUILD_DIR)/VERSION
	$(call print_success,Build completed)

test: ## Run tests
	$(call print_header,Running Tests)
	@./tests/test-runner.sh

lint: ## Run linting checks
	$(call print_header,Linting)
	
	# Check for trailing whitespace
	@if grep -r '[[:space:]]$$' $(SRC_DIR) --include="*.sh" --include="*.md" --exclude-dir=build --exclude-dir=dist; then \
		$(call print_error,Found trailing whitespace); exit 1; \
	else \
		$(call print_success,No trailing whitespace found); \
	fi
	
	# Check for tabs instead of spaces
	@if grep -r $$'\t' $(SRC_DIR) --include="*.sh" --exclude-dir=build --exclude-dir=dist; then \
		$(call print_warning,Found tabs instead of spaces); \
	else \
		$(call print_success,No tabs found); \
	fi

format: ## Format shell scripts
	$(call print_header,Formatting)
	
	# Format with shfmt if available
	@if command -v shfmt >/dev/null 2>&1; then \
		find $(SRC_DIR) -name "*.sh" -not -path "./build/*" -not -path "./dist/*" -exec shfmt -w -i 4 -ci {} \; ; \
		$(call print_success,Scripts formatted with shfmt); \
	else \
		$(call print_warning,shfmt not installed, skipping formatting); \
	fi

check: lint test ## Run all checks (lint + test)

install: build ## Install the utility system-wide
	$(call print_header,Installing System-wide)
	
	# Check if running as root
	@if [ "$$(id -u)" -ne 0 ]; then \
		$(call print_error,Installation requires root privileges. Run with sudo.); \
		exit 1; \
	fi
	
	# Create directories
	@mkdir -p $(BINDIR) $(LIBDIR) $(SHAREDIR) $(CONFIGDIR)
	@mkdir -p $(SHAREDIR)/docs
	@mkdir -p /var/lib/$(PROJECT_NAME) /var/log/$(PROJECT_NAME)
	$(call print_success,Created directories)
	
	# Install executable
	@cp $(BUILD_DIR)/harden-mongo-server $(BINDIR)/
	@chmod 755 $(BINDIR)/harden-mongo-server
	$(call print_success,Installed executable to $(BINDIR))
	
	# Install libraries
	@cp -r $(BUILD_DIR)/lib/harden-mongo-server/* $(LIBDIR)/
	@find $(LIBDIR) -name "*.sh" -exec chmod 644 {} \;
	@cp $(BUILD_DIR)/VERSION $(LIBDIR)/VERSION
	$(call print_success,Installed libraries to $(LIBDIR))
	
	# Install documentation and examples
	@if [ -f $(BUILD_DIR)/README.md ]; then cp $(BUILD_DIR)/README.md $(SHAREDIR)/; fi
	@if [ -d $(BUILD_DIR)/docs ]; then cp -r $(BUILD_DIR)/docs/* $(SHAREDIR)/docs/; fi
	$(call print_success,Installed documentation to $(SHAREDIR))
	
	# Update library path in installed script
	@sed -i 's|readonly LIB_DIR="$$SCRIPT_DIR/lib/harden-mongo-server"|readonly LIB_DIR="$(LIBDIR)"|' $(BINDIR)/harden-mongo-server
	
	# Create system symlink
	@ln -sf $(BINDIR)/harden-mongo-server /usr/bin/harden-mongo-server
	$(call print_success,Created system symlink)
	
	@echo ""
	@echo -e "$(GREEN)Installation completed successfully!$(NO_COLOR)"
	@echo "Run 'harden-mongo-server --help' to get started"

uninstall: ## Uninstall the utility
	$(call print_header,Uninstalling)
	
	# Check if running as root
	@if [ "$$(id -u)" -ne 0 ]; then \
		$(call print_error,Uninstallation requires root privileges. Run with sudo.); \
		exit 1; \
	fi
	
	# Remove files
	@rm -f $(BINDIR)/harden-mongo-server
	@rm -f /usr/bin/harden-mongo-server
	@rm -rf $(LIBDIR)
	@rm -rf $(SHAREDIR)
	$(call print_success,Removed installed files)
	
	@echo ""
	@echo -e "$(GREEN)Uninstallation completed!$(NO_COLOR)"
	@echo "Configuration files in $(CONFIGDIR) and data in /var/lib/$(PROJECT_NAME) have been preserved"

package: build test ## Create distribution packages
	$(call print_header,Creating Packages)
	@mkdir -p $(DIST_DIR)
	
	# Create tarball
	@cd $(BUILD_DIR) && tar -czf ../$(DIST_DIR)/$(PROJECT_NAME)-$(PROJECT_VERSION).tar.gz *
	$(call print_success,Created tarball: $(DIST_DIR)/$(PROJECT_NAME)-$(PROJECT_VERSION).tar.gz)
	
	# Create zip archive
	@cd $(BUILD_DIR) && zip -r ../$(DIST_DIR)/$(PROJECT_NAME)-$(PROJECT_VERSION).zip * >/dev/null
	$(call print_success,Created zip: $(DIST_DIR)/$(PROJECT_NAME)-$(PROJECT_VERSION).zip)
	
	# Create checksums
	@cd $(DIST_DIR) && sha256sum *.tar.gz *.zip > checksums.sha256
	$(call print_success,Created checksums)

dev-setup: ## Set up development environment
	$(call print_header,Development Setup)
	
	# Check for required tools
	@echo "Checking development tools..."
	@for tool in shellcheck shfmt git make; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo -e "  $(GREEN)✓$(NO_COLOR) $$tool"; \
		else \
			echo -e "  $(RED)✗$(NO_COLOR) $$tool (recommended)"; \
		fi; \
	done
	
	# Create development directories
	@mkdir -p $(TEST_DIR) $(DOCS_DIR)
	$(call print_success,Created development directories)
	
	# Initialize git hooks if in git repository
	@if [ -d .git ]; then \
		echo "#!/bin/bash" > .git/hooks/pre-commit; \
		echo "make check" >> .git/hooks/pre-commit; \
		chmod +x .git/hooks/pre-commit; \
		$(call print_success,Created git pre-commit hook); \
	fi

clean: ## Clean build artifacts
	$(call print_header,Cleaning)
	@rm -rf $(BUILD_DIR) $(DIST_DIR)
	$(call print_success,Cleaned build artifacts)

version: ## Show version information
	@echo "MongoDB Server Hardening Tool"
	@echo "Version: $(PROJECT_VERSION)"
	@echo "Build Date: $(BUILD_DATE)"
	@echo "Git Commit: $(GIT_COMMIT)"

.PHONY: all
all: clean build test package ## Build, test, and package everything