.PHONY: all build release test clean install ciall

all: build

build:
	zig build

release:
	zig build --release=fast

test: build
	zig build test
	./zig-out/bin/quizzig examples/advanced.t examples/bare.t examples/basic.t examples/empty.t examples/env.t examples/missingeol.t examples/skip.t examples/test.t
	! ./zig-out/bin/quizzig examples/fail.t
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
