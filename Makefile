# Ghostty helpers.
#
# Preferred workflow when Zig isn't installed locally:
#   make docker-image   # once
#   make build          # zig build (GTK Linux) inside Docker
#   make test           # zig build test inside Docker
#   make shell          # interactive container shell
#
# Override Zig flags with ZIG_FLAGS, e.g.:
#   make test ZIG_FLAGS='-Dtest-filter=macos-tabs-location'
# Skip Docker when a local zig is available:
#   make build USE_DOCKER=0

DOCKER_IMAGE ?= ghostty-dev
DOCKER_FILE  ?= Dockerfile
DISTRO_VERSION ?= 13
ZIG_VERSION ?=
ZIG_FLAGS ?=
TEST_FILTER ?=
USE_DOCKER ?= 1

# Persistent Zig package/cache volume across container runs.
DOCKER_CACHE_VOLUME ?= ghostty-zig-cache

DOCKER_RUN_BASE = docker run --rm \
	-v "$(CURDIR):/src" \
	-v "$(DOCKER_CACHE_VOLUME):/zig-cache" \
	-e ZIG_GLOBAL_CACHE_DIR=/zig-cache \
	-w /src

# Allocate a TTY for interactive targets when stdin is a terminal.
ifeq ($(shell test -t 0 && echo tty),tty)
DOCKER_TTY := -it
else
DOCKER_TTY :=
endif

ifeq ($(USE_DOCKER),1)
RUN = $(DOCKER_RUN_BASE) $(DOCKER_IMAGE)
SHELL_RUN = $(DOCKER_RUN_BASE) $(DOCKER_TTY) $(DOCKER_IMAGE)
else
RUN =
SHELL_RUN =
endif

.DEFAULT_GOAL := help

help:
	@echo "Ghostty make targets"
	@echo ""
	@echo "  docker-image   Build the Zig+GTK toolchain image ($(DOCKER_IMAGE))"
	@echo "  shell          Open a shell in the toolchain container"
	@echo "  version        Print zig / ghostty version info"
	@echo "  build          zig build (Debug, GTK Linux)"
	@echo "  build-release  zig build -Doptimize=ReleaseFast"
	@echo "  build-lib-vt   zig build -Demit-lib-vt"
	@echo "  test           zig build test"
	@echo "  test-lib-vt    zig build test-lib-vt"
	@echo "  test-filter    zig build test -Dtest-filter=\$$TEST_FILTER"
	@echo "  fmt            zig fmt ."
	@echo "  fmt-check      zig fmt --check ."
	@echo "  run            zig build run"
	@echo "  clean          Remove local build artifacts"
	@echo ""
	@echo "Variables: USE_DOCKER=$(USE_DOCKER) ZIG_FLAGS='$(ZIG_FLAGS)' TEST_FILTER='$(TEST_FILTER)'"
.PHONY: help

# ---------------------------------------------------------------------------
# Docker toolchain
# ---------------------------------------------------------------------------

docker-image:
	docker volume create "$(DOCKER_CACHE_VOLUME)" >/dev/null
	docker build \
		-f "$(DOCKER_FILE)" \
		--build-arg "DISTRO_VERSION=$(DISTRO_VERSION)" \
		$(if $(ZIG_VERSION),--build-arg "ZIG_VERSION=$(ZIG_VERSION)",) \
		-t "$(DOCKER_IMAGE)" \
		.
.PHONY: docker-image

shell: docker-image
	$(SHELL_RUN) bash
.PHONY: shell

# ---------------------------------------------------------------------------
# Build / test / format (run in Docker by default)
# ---------------------------------------------------------------------------

version: docker-image
	$(RUN) zig version
	-$(RUN) ./zig-out/bin/ghostty +version
.PHONY: version

build: docker-image
	$(RUN) zig build -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: build

build-release: docker-image
	$(RUN) zig build -Doptimize=ReleaseFast -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: build-release

build-lib-vt: docker-image
	$(RUN) zig build -Demit-lib-vt -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: build-lib-vt

test: docker-image
	$(RUN) zig build test -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: test

test-lib-vt: docker-image
	$(RUN) zig build test-lib-vt -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: test-lib-vt

test-filter: docker-image
	@test -n "$(TEST_FILTER)" || (echo "TEST_FILTER is required, e.g. make test-filter TEST_FILTER=macos-tabs-location" >&2; exit 1)
	$(RUN) zig build test -Dcpu=baseline -Dtest-filter="$(TEST_FILTER)" $(ZIG_FLAGS)
.PHONY: test-filter

fmt: docker-image
	$(RUN) zig fmt .
.PHONY: fmt

fmt-check: docker-image
	$(RUN) zig fmt --check .
.PHONY: fmt-check

run: docker-image
	$(SHELL_RUN) zig build run -Dcpu=baseline $(ZIG_FLAGS)
.PHONY: run

# ---------------------------------------------------------------------------
# Existing local helpers
# ---------------------------------------------------------------------------

init:
	@echo You probably want to run "zig build" or "make build" instead.
.PHONY: init

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean
