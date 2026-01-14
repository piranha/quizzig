Set up quizzig alias:

  $ . "$TESTDIR"/setup.sh

Help shows usage line:

  $ quizzig -h | head -1
  Usage: quizzig [OPTIONS] [TEST_FILES...]

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
  Usage: quizzig [OPTIONS] [TEST_FILES...]

No tests found in empty directory:

  $ mkdir empty
  $ quizzig empty
  No test files found.
