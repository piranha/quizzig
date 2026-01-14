Set up quizzig alias:

    $ . "$TESTDIR"/setup.sh

Test with Latin-1 encoding:

    $ cat > good-latin-1.t <<EOF
    >     $ printf "hola se\361or\n"
    >     hola se\xf1or (esc)
    > EOF

    $ cat > bad-latin-1.t <<EOF
    >     $ printf "hola se\361or\n"
    >     hey
    > EOF

    $ quizzig good-latin-1.t bad-latin-1.t
    --- bad-latin-1.t
    +++ bad-latin-1.t
    @@ -2,1 +2,1 @@
    -    hey
    +    hola se\xf1or (esc)
    !.
    # Ran 2 tests, 0 skipped, 1 failed.
    [1]

Test with UTF-8 encoding:

    $ cat > good-utf-8.t <<EOF
    >     $ printf "hola se\303\261or\n"
    >     hola se\xc3\xb1or (esc)
    > EOF

    $ cat > bad-utf-8.t <<EOF
    >     $ printf "hola se\303\261or\n"
    >     hey
    > EOF

    $ quizzig good-utf-8.t bad-utf-8.t
    --- bad-utf-8.t
    +++ bad-utf-8.t
    @@ -2,1 +2,1 @@
    -    hey
    +    hola se\xc3\xb1or (esc)
    !.
    # Ran 2 tests, 0 skipped, 1 failed.
    [1]

Test file missing trailing newline:

    $ printf '    $ true' > passing-with-no-newline.t
    $ quizzig passing-with-no-newline.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

    $ printf '    $ false' > failing-with-no-newline.t
    $ quizzig failing-with-no-newline.t
    --- failing-with-no-newline.t
    +++ failing-with-no-newline.t
    @@ -2,0 +2,1 @@
    +    [1]
    !
    # Ran 1 tests, 0 skipped, 1 failed.
    [1]
