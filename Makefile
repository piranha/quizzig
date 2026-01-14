.PHONY: all build release test clean install ciall

all: build

build:
	zig build

release:
	zig build --release=fast

test: build
	zig build test
	./zig-out/bin/quizzig examples/advanced.md examples/bare.md examples/basic.md examples/empty.md examples/env.md examples/missingeol.md examples/skip.md examples/test.md
	! ./zig-out/bin/quizzig examples/fail.md 2>&1 > /dev/null
	./zig-out/bin/quizzig --bindir ./zig-out/bin tests/

clean:
	rm -rf zig-out .zig-cache

install: release
	cp zig-out/bin/quizzig /usr/local/bin/

ciall:
	zig build --release=fast -Dtarget=x86_64-linux-musl  -Doutput=dist/quizzig-Linux-x86_64
	zig build --release=fast -Dtarget=aarch64-linux-musl -Doutput=dist/quizzig-Linux-aarch64
	zig build --release=fast -Dtarget=x86_64-macos       -Doutput=dist/quizzig-Darwin-x86_64
	zig build --release=fast -Dtarget=aarch64-macos      -Doutput=dist/quizzig-Darwin-arm64
	zig build --release=fast -Dtarget=x86_64-windows     -Doutput=dist/quizzig-Windows-x86_64.exe
