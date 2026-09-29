# Developer shortcuts. On Linux the Swift toolchain lives wherever `swift` resolves; on macOS use Xcode's.
SWIFT ?= swift

.PHONY: build test test-verbose clean project sim

build:
	$(SWIFT) build

test:
	$(SWIFT) test 2>&1 | grep -E "✘|✔ Suite|Test run|error:" || true

test-verbose:
	$(SWIFT) test

clean:
	rm -rf .build

# Generates App/Dashcam.xcodeproj from App/project.yml (requires `brew install xcodegen`).
project:
	cd App && xcodegen generate

sim:
	$(SWIFT) run dashcam-sim $(ARGS)
