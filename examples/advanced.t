Multi-line commands:

  $ foo() {
  >     echo "hello from foo"
  > }
  $ foo
  hello from foo

  $ for i in 1 2 3; do
  >     echo "item $i"
  > done
  item 1
  item 2
  item 3

Regular expressions:

  $ echo "2024-01-15"
  \d{4}-\d{2}-\d{2} (re)

  $ echo "Hello World 123"
  Hello \w+ \d+ (re)

  $ echo foobarbaz
  foo.*baz (re)

  $ echo "user@example.com"
  \w+@\w+\.\w+ (re)

  $ echo "abc 123 xyz"
  [a-z]+\s+\d+\s+[a-z]+ (re)

  $ echo "YES or NO"
  (YES|NO) or (YES|NO) (re)

  $ echo "file.txt"
  file\.(txt|md|py) (re)

  $ echo "  spaces  "
  \s+spaces\s+ (re)

Escape sequences:

  $ printf 'hello\tworld\n'
  hello\tworld (esc)

  $ printf '\x00\x01\x02'
  \x00\x01\x02 (esc)

No trailing newline:

  $ printf "no newline"
  no newline (no-eol)

  $ printf "line1\nline2"
  line1
  line2 (no-eol)

Stderr merging:

  $ echo "to stderr" >&2
  to stderr

  $ echo "stdout"; echo "stderr" >&2
  stdout
  stderr

Environment variables:

  $ echo "$TESTFILE"
  advanced.t

  $ test -n "$TESTDIR"

  $ test -n "$CRAMTMP"

