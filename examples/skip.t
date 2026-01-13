Skipping tests:

Exit code 80 marks a command as skipped.

  $ (exit 80)

  $ echo "this runs"
  this runs

Conditional skip:

  $ test -f /nonexistent/file && echo found || (exit 80)

  $ echo "after conditional skip"
  after conditional skip
