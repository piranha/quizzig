Set up quizzig alias and example tests:

    $ . "$TESTDIR"/setup.sh

Run quizzig examples:

    $ quizzig -E -q examples examples/fail.md
    ...s.!!...
    # Ran 55 tests, 3 skipped, 10 failed.
    [1]

Run examples with bash:

    $ quizzig -E --shell=/bin/bash -q examples examples/fail.md
    ...s.!!...
    # Ran 55 tests, 3 skipped, 10 failed.
    [1]

Verbose mode:

    $ quizzig -E -q -v examples examples/fail.md
    examples/advanced.md: .
    examples/bare.md: .
    examples/basic.md: .
    examples/empty.md: s
    examples/env.md: .
    examples/fail.md: !
    examples/fail.md: !
    examples/missingeol.md: .
    examples/skip.md: .
    examples/test.md: .
    
    # Ran 55 tests, 3 skipped, 10 failed.
    # Skipped:
    #   examples/empty.md: (no commands)
    #   examples/skip.md:5: (exit 80)
    #   examples/skip.md:12: test -f /nonexistent/file && echo found || (exit 80)
    [1]

Test that a simple passing test works:

    $ echo "    $ echo 1" > simple.md
    $ quizzig -E simple.md
    !
    --- simple.md
    +++ simple.md
    @@ -1,1 +1,2 @@
         $ echo 1
    +    1
    
    # Ran 1 tests, 0 skipped, 1 failed.
    [1]
    $ printf "    $ echo 1\n    1\n" > simple.md
    $ quizzig -E simple.md
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Custom indentation:

    $ cat > indent.md <<EOF
    > Indented by 4 spaces:
    >
    >   $ echo foo
    >   foo
    >
    > Not part of the test:
    >
    >     $ echo foo
    >     bar
    > EOF
    $ quizzig -E --indent=2 indent.md
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test running tests with the same filename in different directories:

    $ mkdir subdir1 subdir2
    $ cat > subdir1/test.md <<EOF
    >     $ echo 1
    > EOF
    $ cat > subdir2/test.md <<EOF
    >     $ echo 2
    > EOF
    $ quizzig -E subdir1 subdir2
    !!
    --- subdir1/test.md
    +++ subdir1/test.md
    @@ -1,1 +1,2 @@
         $ echo 1
    +    1
    --- subdir2/test.md
    +++ subdir2/test.md
    @@ -1,1 +1,2 @@
         $ echo 2
    +    2
    
    # Ran 2 tests, 0 skipped, 2 failed.
    [1]
