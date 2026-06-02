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

Verbose trace streams command output before the command exits:

    $ cat > stream.md <<'EOF'
    >     $ echo streamed
    >     > touch "$TESTDIR/stream-ready"
    >     > while [ ! -f "$TESTDIR/stream-release" ]; do sleep 0.05; done
    >     streamed
    > EOF
    $ quizzig -vv stream.md >trace.out 2>&1 & pid=$!
    $ i=0; while [ ! -f stream-ready ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
    $ grep -q '^    streamed$' trace.out && echo streamed-before-wait
    streamed-before-wait
    $ touch stream-release
    $ wait $pid

Verbose mode with empty test:

    $ quizzig -v examples/empty.md
    examples/empty.md: s
    
    # Ran 0 tests, 1 skipped, 0 failed.
    # Skipped:
    #   examples/empty.md: (no commands)
