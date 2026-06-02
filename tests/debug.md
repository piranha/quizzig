Set up quizzig alias:

    $ . "$TESTDIR"/setup.sh

Verbose trace renders markdown with actual output and status:

    $ printf '    $ echo hi\n    > echo bye\n    hi\n    bye\n' > debug.md
    $ quizzig -vv debug.md
    # quizzig trace: debug.md
        $ echo hi
        > echo bye
        hi
        bye
    # quizzig: PASS line 1
    
    # Ran 1 tests, 0 skipped, 0 failed.

Debug mode is an alias for verbose trace:

    $ quizzig -d debug.md
    # quizzig trace: debug.md
        $ echo hi
        > echo bye
        hi
        bye
    # quizzig: PASS line 1
    
    # Ran 1 tests, 0 skipped, 0 failed.

Verbose mode with empty test:

    $ quizzig -v examples/empty.md
    examples/empty.md: s
    
    # Ran 0 tests, 1 skipped, 0 failed.
    # Skipped:
    #   examples/empty.md: (no commands)
