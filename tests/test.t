Set up quizzig alias and example tests:

  $ . "$TESTDIR"/setup.sh

Run quizzig examples:

  $ quizzig -q examples examples/fail.t
  ...s.!!...
  # Ran 55 tests, 3 skipped, 10 failed.
  [1]

Run examples with bash:

  $ quizzig --shell=/bin/bash -q examples examples/fail.t
  ...s.!!...
  # Ran 55 tests, 3 skipped, 10 failed.
  [1]

Verbose mode:

  $ quizzig -q -v examples examples/fail.t
  examples/advanced.t: .
  examples/bare.t: .
  examples/basic.t: .
  examples/empty.t: s
  examples/env.t: .
  examples/fail.t: !
  examples/fail.t: !
  examples/missingeol.t: .
  examples/skip.t: .
  examples/test.t: .
  
  # Ran 55 tests, 3 skipped, 10 failed.
  [1]

Test that a simple passing test works:

  $ echo "  $ echo 1" > simple.t
  $ quizzig simple.t
  --- simple.t
  +++ simple.t
  @@ -2,0 +2,1 @@
  +  1
  !
  # Ran 1 tests, 0 skipped, 1 failed.
  [1]
  $ printf "  $ echo 1\n  1\n" > simple.t
  $ quizzig simple.t
  .
  # Ran 1 tests, 0 skipped, 0 failed.

Custom indentation:

  $ cat > indent.t <<EOF
  > Indented by 4 spaces:
  >
  >     $ echo foo
  >     foo
  >
  > Not part of the test:
  >
  >   $ echo foo
  >   bar
  > EOF
  $ quizzig --indent=4 indent.t
  .
  # Ran 1 tests, 0 skipped, 0 failed.

Test running tests with the same filename in different directories:

  $ mkdir subdir1 subdir2
  $ cat > subdir1/test.t <<EOF
  >   $ echo 1
  > EOF
  $ cat > subdir2/test.t <<EOF
  >   $ echo 2
  > EOF
  $ quizzig subdir1 subdir2
  --- subdir1/test.t
  +++ subdir1/test.t
  @@ -2,0 +2,1 @@
  +  1
  !--- subdir2/test.t
  +++ subdir2/test.t
  @@ -2,0 +2,1 @@
  +  2
  !
  # Ran 2 tests, 0 skipped, 2 failed.
  [1]
