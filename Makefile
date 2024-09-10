ifeq ($(filter -j%, $(MAKEFLAGS)),)
    JOBS := 1  # Default to 1 if no -j flag is provided
else
    JOBS := $(shell echo $(MAKEFLAGS) | sed -n 's/.*-j\([0-9]*\).*/\1/p')
endif

.PHONY: build benchmark-mp download-linux-repo

# Create the binary
build:
	zig build -j$(JOBS)

# Run the multiprocessing benchmarks.
benchmark-mp: build download-linux-repo
	mkdir -p build
	./build-tools/bench-mp.sh ./zig-out/bin/rabbit-search "example" third-party/linux build

# Download the linux repo
download-linux-repo:
	git submodule update --init third-party/linux
