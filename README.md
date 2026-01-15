# quizzig

A shell testing framework. Inspired by [cram](https://bitheap.org/cram/).

Write tests that look like shell sessions, quizzig runs them and diffs the output.

## Why

Cram is in Python, which means you need to have Python and have to survive
Python's load time etc. Quizzig is written in Zig, so startup is quick and it's
distributed as a single small binary.

## Installation

```bash
curl -fsSL https://github.com/piranha/quizzig/releases/latest/download/quizzig-$(uname -s)-$(uname -m) \
  -o ~/.local/bin/quizzig && chmod +x ~/.local/bin/quizzig
```

Or grab a binary from [releases](https://github.com/piranha/quizzig/releases).

> [!NOTE]
> macOS users: if you get a quarantine warning, run `xattr -d com.apple.quarantine ~/.local/bin/quizzig`

## Usage

```sh
quizzig [OPTIONS] [TEST_FILES...]
```

**Options:**
- `-h, --help` - Show help
- `-V, --version` - Show version
- `-q, --quiet` - Don't print diffs
- `-v, --verbose` - Show filenames and status
- `--shell=PATH` - Shell to use (default: `/bin/sh`)
- `--indent=N` - Indentation spaces (default: 2)
- `-E, --inherit-env` - Inherit parent environment as base
- `-e VAR=VAL, --env VAR=VAL` - Set environment variable (repeatable)
- `--bindir=DIR` - Prepend DIR to PATH (repeatable)

## Test Format

You can literally write tests as markdown files, using 4-space indented blocks for test content:

```
Description (not indented, ignored):

    $ echo hello
    hello

    $ echo "multi
    > line
    > command"
    multi
    line
    command
```

> [!NOTE]
> Cram uses 2-space indents by default, you can use `quizzig --indent=2` to support old format.

### Commands

Lines starting with `  $ ` are shell commands. Continuation lines use `  > `.

### Expected Output

Indented lines after a command are expected output. Supports several matchers:

**Literal** (default):
```
    $ echo foo
    foo
```

**Regex** `(re)`:
```
    $ date
    \d{4}-\d{2}-\d{2}.* (re)
```

**Glob** `(glob)`:
```
    $ ls *.txt
    file?.txt (glob)
```

**Escape sequences** `(esc)`:
```
    $ printf '\x00\x01'
    \x00\x01 (esc)
```

**No trailing newline** `(no-eol)`:
```
    $ printf foo
    foo (no-eol)
```

### Exit Codes

Non-zero exit codes are shown as `[N]`:
```
    $ (exit 1)
    [1]
```

### Skipping Tests

Exit with code 80 to skip:
```
    $ [ -f /some/file ] || exit 80
```

## Environment

Tests run in isolated temp directories with a minimal, controlled environment.

**Variables set for tests:**
- `TESTDIR` - Absolute path to test file's directory
- `TESTFILE` - Test file basename
- `TESTSHELL` - Shell being used
- `ROOTDIR` - Directory where quizzig was invoked
- `CRAMTMP` - Temp directory root
- `QUIZZIG` - Always "1"

**Default PATH:** `/usr/local/bin:/usr/bin:/bin` (use `--bindir` to prepend directories)

Standard locale variables (`LANG`, `LC_ALL`, `TZ`, etc.) are normalized to `C`.

## Example

```sh
# examples/basic.t
Basic shell tests:

    $ echo hello world
    hello world

    $ seq 3
    1
    2
    3

    $ ls *.md
    README.md (glob)

    $ (exit 42)
    [42]
```

Run:
```sh
$ quizzig examples/basic.t
.
# Ran 4 tests, 0 skipped, 0 failed.
```

Accept actual output (update test file with real output):
```sh
$ quizzig test.t 2>/dev/null | patch -p0
```

**Testing your own binaries:**
```sh
# Add build output to PATH so tests can find your binaries
$ quizzig --bindir ./zig-out/bin tests/*.t

# Or use ROOTDIR in tests to reference project root
$ echo '$ROOTDIR/zig-out/bin/mybin --help' > tests/help.t
```

**Inheriting environment:**
```sh
# Inherit parent env + add custom vars
$ quizzig -E -e DEBUG=1 tests/*.t
```

## Building

Requires Zig 0.15+. PCRE2 is fetched and compiled automatically.

```sh
make          # Debug build
make release  # Release build
make test     # Run tests
```
