import QtQuick
import Quickshell.Io

// A process whose result arrives once: `finished` fires after the process
// exited and both of its output streams were read, in whatever order those
// happen. A stream something keeps open (a stray grandchild) cannot hold
// the result back for more than a couple of seconds, and a program that
// never starts (missing, not executable) finishes with exit code -1 instead
// of leaving its caller waiting.
Process {
  id: command

  property string output: ""
  property string errorOutput: ""
  property var context: null

  property bool _started: false
  property bool _exited: false
  property bool _outDone: false
  property bool _errDone: false
  property bool _reported: true
  property int _code: 0

  signal finished(int exitCode, string output, string errorOutput, var context)

  function run(argv, ctx) {
    _started = false
    _exited = false
    _outDone = false
    _errDone = false
    _reported = false
    output = ""
    errorOutput = ""
    context = ctx === undefined ? null : ctx
    exec(argv)
    startGrace.restart()
  }

  function _settle() {
    if (_reported || !_exited || !(_outDone && _errDone)) return
    _reported = true
    streamGrace.stop()
    finished(_code, output, errorOutput, context)
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      command.output = text
      command._outDone = true
      command._settle()
    }
  }

  stderr: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      command.errorOutput = text
      command._errDone = true
      command._settle()
    }
  }

  onStarted: _started = true

  onExited: function(exitCode) {
    _code = exitCode
    _exited = true
    if (!(_outDone && _errDone)) streamGrace.restart()
    _settle()
  }

  // Quickshell reports no exit for a program that failed to start.
  property Timer startGrace: Timer {
    interval: 3000
    onTriggered: {
      if (command._started || command._exited || command._reported) return
      command._code = -1
      command._exited = true
      command._outDone = true
      command._errDone = true
      command.errorOutput = "could not start " + (command.command && command.command.length ? command.command[0] : "the command")
      command._settle()
    }
  }

  property Timer streamGrace: Timer {
    interval: 2000
    onTriggered: {
      command._outDone = true
      command._errDone = true
      command._settle()
    }
  }
}
