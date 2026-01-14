Set up quizzig alias:

    $ . "$TESTDIR"/setup.sh

Test ROOTDIR environment variable:

    $ cat > rootdir.t <<EOF
    >     $ echo "\$ROOTDIR" | grep -q / && echo "has path"
    >     has path
    > EOF
    $ quizzig rootdir.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test --env flag:

    $ cat > envtest.t <<EOF
    >     $ echo "\$MYVAR"
    >     hello
    > EOF
    $ quizzig -e MYVAR=hello envtest.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test --env overrides inherited:

    $ cat > envoverride.t <<EOF
    >     $ echo "\$HOME"
    >     custom
    > EOF
    $ quizzig -E -e HOME=custom envoverride.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test --bindir prepends to PATH:

    $ mkdir mybin
    $ cat > mybin/mytool <<EOF
    > #!/bin/sh
    > echo "mytool works"
    > EOF
    $ chmod +x mybin/mytool
    $ cat > bintest.t <<EOF
    >     $ mytool
    >     mytool works
    > EOF
    $ quizzig --bindir=mybin bintest.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test multiple --bindir (last wins = first in PATH):

    $ mkdir bin1 bin2
    $ printf '#!/bin/sh\necho bin1' > bin1/tool
    $ printf '#!/bin/sh\necho bin2' > bin2/tool
    $ chmod +x bin1/tool bin2/tool
    $ cat > multibin.t <<EOF
    >     $ tool
    >     bin2
    > EOF
    $ quizzig --bindir=bin1 --bindir=bin2 multibin.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Test -E inherits environment:

    $ cat > inherit.t <<EOF
    >     $ echo "\$QUIZZIG"
    >     1
    > EOF
    $ MYTEST=inherited quizzig inherit.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

    $ cat > inherit2.t <<EOF
    >     $ echo "\$MYTEST"
    >     inherited
    > EOF
    $ MYTEST=inherited quizzig -E inherit2.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.

Default PATH includes standard directories:

    $ cat > path.t <<EOF
    >     $ echo "\$PATH" | tr ':' '\n' | head -3
    >     /usr/local/bin
    >     /usr/bin
    >     /bin
    > EOF
    $ quizzig path.t
    .
    # Ran 1 tests, 0 skipped, 0 failed.
