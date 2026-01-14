.PHONY: all build release test clean install ciall

all: build

build:
	zig build

release:
	zig build --release=fast

test: build
	zig build test
	./zig-out/bin/quizzig --bindir ./zig-out/bin tests/

clean:
	rm -rf zig-out .zig-cache

install: release
	cp zig-out/bin/quizzig /usr/local/bin/

ifndef VERSION
ciall:
	$(error VERSION is not set)
else
ciall:
	zig build --release=fast -Dversion=${VERSION} -Dtarget=aarch64-macos      -Doutput=dist/quizzig-Darwin-arm64
	zig build --release=fast -Dversion=${VERSION} -Dtarget=x86_64-macos       -Doutput=dist/quizzig-Darwin-x86_64
	zig build --release=fast -Dversion=${VERSION} -Dtarget=aarch64-linux-musl -Doutput=dist/quizzig-Linux-aarch64
	zig build --release=fast -Dversion=${VERSION} -Dtarget=x86_64-linux-musl  -Doutput=dist/quizzig-Linux-x86_64
	zig build --release=fast -Dversion=${VERSION} -Dtarget=x86_64-windows     -Doutput=dist/quizzig-Windows-x86_64.exe
endif
