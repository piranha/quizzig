Set up quizzig alias:

  $ . "$TESTDIR"/setup.sh

Debug mode outputs directly to terminal:

  $ printf '  $ echo hi\n  > echo bye' > debug.t
  $ quizzig -d debug.t
  hi
  bye
  .
  # Ran 1 tests, 0 skipped, 0 failed.

Debug mode with empty test:

  $ quizzig -d examples/empty.t
  s
  # Ran 0 tests, 1 skipped, 0 failed.
