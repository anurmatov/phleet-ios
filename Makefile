# Build entry points. Every target here is what CI runs, so a green CI run and a local run
# are the same commands.
#
# `lint` and `selftest` need only bash and python3 and run anywhere.
# `icon` regenerates the committed app icon; it needs only python3 and is not part of a build.
# `generate`, `build` and `test` need macOS with the pinned Xcode (see docs/development.md).

SHELL := /bin/bash

XCODEGEN      := .tools/xcodegen/bin/xcodegen
PROJECT       := Phleet.xcodeproj
SCHEME        := Phleet
RESULT_BUNDLE := build/Phleet.xcresult

# D8: the build number is the CI run number, falling back to 1 for local builds. An .xcconfig
# cannot express this, so it is passed on the xcodebuild invocation instead.
BUILD_NUMBER := $(if $(GITHUB_RUN_NUMBER),$(GITHUB_RUN_NUMBER),1)

XCODEBUILD_FLAGS := \
    -project $(PROJECT) \
    -scheme $(SCHEME) \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

.PHONY: all generate build test lint selftest icon clean

all: lint selftest generate test

generate:
	@test -x "$(XCODEGEN)" || { \
	    echo "error: XcodeGen not found at $(XCODEGEN)." >&2; \
	    echo "Run ./scripts/bootstrap.sh first; it fetches the pinned, hash-verified release." >&2; \
	    exit 1; \
	}
	"$(XCODEGEN)" generate --spec project.yml --project .

build: generate
	@DEST="$$(./scripts/select-simulator.sh)" && \
	    echo "Destination: $$DEST" && \
	    xcodebuild $(XCODEBUILD_FLAGS) -destination "$$DEST" build

test: generate
	@mkdir -p build
	@rm -rf "$(RESULT_BUNDLE)"
	@DEST="$$(./scripts/select-simulator.sh)" && \
	    echo "Destination: $$DEST" && \
	    xcodebuild $(XCODEBUILD_FLAGS) -destination "$$DEST" \
	        -resultBundlePath "$(RESULT_BUNDLE)" clean test

lint:
	./scripts/check-no-private-values.sh
	./scripts/check-app-icon.sh

selftest:
	./scripts/select-simulator.sh --self-test
	./scripts/check-no-private-values.sh --self-test
	./scripts/check-release-inputs.sh --self-test
	./scripts/check-app-icon.sh --self-test

# The icon is committed, because Xcode needs the file to exist at build time. This target
# regenerates it from scripts/make-app-icon.py so the artwork stays reviewable as source: change
# a number, re-run, get a byte-identical result. Run it only when the artwork changes.
icon:
	python3 scripts/make-app-icon.py
	./scripts/check-app-icon.sh

clean:
	rm -rf build "$(PROJECT)" DerivedData
