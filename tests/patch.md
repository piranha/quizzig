# Test that quizzig output can be piped to patch

Create a test file with wrong expected output:

    $ cat << 'EOF' > test.md
    > Test:
    >
    >     $ echo hello
    >     wrong
    >     $ echo world
    >     also wrong
    > EOF

Run quizzig and verify it fails:

    $ quizzig test.md; echo "exit: $?"
    !
    --- test.md
    +++ test.md
    @@ -1,6 +1,6 @@
     Test:
     
         $ echo hello
    -    wrong
    +    hello
         $ echo world
    -    also wrong
    +    world
    
    # Ran 2 tests, 0 skipped, 2 failed.
    exit: 1

         $ echo hello
    -    wrong
    +    hello
         $ echo world
    -    also wrong
    +    world

    # Ran 2 tests, 0 skipped, 2 failed.
    exit: 1

Pipe to patch and verify it succeeds:

    $ quizzig test.md 2>/dev/null | patch -p0
    patching file test.md

Now the test should pass:

    $ quizzig test.md; echo "exit: $?"
    .
    # Ran 2 tests, 0 skipped, 0 failed.
    exit: 0

Verify file was updated - check the fixed lines:

    $ sed -n '4p;6p' test.md
        hello
        world

Test with UTF-8 content (box drawings, accented chars):

    $ cat << 'EOF' > utf8.md
    > Test UTF-8:
    >
    >     $ printf "── hello ──\n"
    >     wrong
    >     $ printf "café\n"
    >     also wrong
    > EOF

    $ quizzig utf8.md; echo "exit: $?"
    !
    --- utf8.md
    +++ utf8.md
    @@ -1,6 +1,6 @@
     Test UTF-8:
     
         $ printf "── hello ──\n"
    -    wrong
    +    ── hello ──
         $ printf "café\n"
    -    also wrong
    +    café
    
    # Ran 2 tests, 0 skipped, 2 failed.
    exit: 1

         $ printf "── hello ──\n"
    -    wrong
    +    ── hello ──
         $ printf "café\n"
    -    also wrong
    +    café

    # Ran 2 tests, 0 skipped, 2 failed.
    exit: 1

Patch with UTF-8 content should work:

    $ quizzig utf8.md 2>/dev/null | patch -p0
    patching file utf8.md

    $ quizzig utf8.md; echo "exit: $?"
    .
    # Ran 2 tests, 0 skipped, 0 failed.
    exit: 0

    $ sed -n '4p;6p' utf8.md
        ── hello ──
        café
