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

Color can be forced for verbose trace status lines:

    $ cat > color-status.md <<'EOF'
    >     $ true
    >     $ false
    >     $ (exit 80)
    > EOF
    $ quizzig --color=always -vv color-status.md >color.out 2>&1 || true
    $ esc=$(printf '\033')
    $ grep "^# quizzig: ${esc}\\[32mPASS${esc}\\[0m line 1$" color.out >/dev/null && echo green-pass
    green-pass
    $ grep "^# quizzig: ${esc}\\[31mFAIL${esc}\\[0m line 2$" color.out >/dev/null && echo red-fail
    red-fail
    $ grep "^# quizzig: ${esc}\\[33mSKIP${esc}\\[0m line 3$" color.out >/dev/null && echo yellow-skip
    yellow-skip

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
