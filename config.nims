import ospaths

const BIN_DIR = "bin"
const BUILD_DIR = "build"

template dep(name: untyped): untyped =
  exec "nim " & astToStr(name)

proc buildExe(debug: bool, bin: string, src: string, cpp = false) =
  switch("out", (thisDir() & "/" & bin).toExe)
  switch("nimcache", BUILD_DIR)
  if not debug:
    --forceBuild
    --define: release
    --opt: size
  else:
    --define: debug
    --debuginfo
    --debugger: native
    --linedir: on
    --stacktrace: on
    --linetrace: on
    --verbosity: 1

  --threads: on

  --NimblePath: src
  --NimblePath: srcDir

  setCommand(if cpp: "cpp" else: "c", src)

proc test(name: string, cpp = false) =
  if not BIN_DIR.dirExists:
    BIN_DIR.mkDir
  --run
  buildExe(true, "bin" / "test_" & name, "tests" / "test_" & name, cpp = cpp)

task test, "Test asynchttpserver2":
  test "asynchttpserver2"
