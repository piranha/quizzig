# quizzig

A shell testing framework written in Zig. Inspired by [cram](https://bitheap.org/cram/).

Write tests that look like shell sessions, quizzig runs them and diffs the output.

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

## Test Format

Test files use `.t` extension. Lines indented with 2 spaces are test content:

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

Tests run in isolated temp directories. These variables are set:

- `TESTDIR` - Directory containing the test file
- `TESTFILE` - Test file basename
- `TESTSHELL` - Shell being used
- `CRAMTMP` - Temp directory root

Standard locale variables (`LANG`, `LC_ALL`, `TZ`, etc.) are normalized.

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

## Building

Requires Zig 0.15+. PCRE2 is fetched and compiled automatically.

```sh
zig build              # Debug build
zig build -Doptimize=ReleaseFast  # Release build
zig build test         # Run unit tests
```
