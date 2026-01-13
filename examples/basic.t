Basic output matching:

  $ echo hello
  hello

  $ echo "foo bar"
  foo bar

  $ echo 1; echo 2; echo 3
  1
  2
  3

Glob patterns:

  $ echo hello.txt
  *.txt (glob)

  $ echo "file1 file2 file3"
  file? file? file? (glob)

Exit codes:

  $ (exit 0)

  $ (exit 1)
  [1]

  $ (exit 42)
  [42]

Empty output:

  $ true
