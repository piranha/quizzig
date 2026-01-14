#!/bin/sh

# Bash doesn't expand aliases by default in non-interactive mode
[ "$TESTSHELL" = "/bin/bash" ] && shopt -s expand_aliases

# Use quizzig from ROOTDIR build, or fall back to PATH
if [ -x "$ROOTDIR/zig-out/bin/quizzig" ]; then
  alias quizzig="$ROOTDIR/zig-out/bin/quizzig --shell=$TESTSHELL"
else
  alias quizzig="quizzig --shell=$TESTSHELL"
fi

command -v md5 > /dev/null || alias md5=md5sum

# Copy example tests into temp directory
cp -R "$TESTDIR"/../examples .
find . -name '*.err' -exec rm '{}' \;
