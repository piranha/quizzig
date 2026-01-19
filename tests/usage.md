Set up quizzig alias:

    $ . "$TESTDIR"/setup.sh

Help shows usage line:

    $ quizzig -h | head -1
    quizzig - A shell testing framework written in Zig.

Help mentions key flags:

    $ quizzig -h | grep -c '\-\-bindir'
    1
    $ quizzig -h | grep -c '\-\-env'
    1
    $ quizzig -h | grep -c 'inherit-env'
    1
    $ quizzig -h | grep -c 'ROOTDIR'
    1

Version output:

    $ quizzig -V
    quizzig * (glob)

No arguments shows usage:

    $ quizzig | head -1
    quizzig - A shell testing framework written in Zig.

No tests found in empty directory:

    $ mkdir empty
    $ quizzig empty
    No test files found.
