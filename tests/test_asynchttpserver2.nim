import unittest,
       asynchttpserver2,
       asyncdispatch,
       threadpool,
       httpclient,
       net,
       strutils,
       streams

const PORT = 9999.Port
const HOST = "localhost"

proc processBigData(req: Request) {.async.} =
  let s = req.body.getStream
  var buff: array[4096, char]
  var length = 0
  while true:
    let readed = s.readData(addr buff, buff.len)
    if readed == 0:
      break
    length += readed
  await req.respond(Http200, $length)

proc serverThread =
  var server = newAsyncHttpServer()
  proc cb(req: Request) {.async.} =
    case req.reqMethod
    of "get":
      await req.respond(Http200, "Hello, world!")
    of "post":
      if req.url.path == "/count":
        await processBigData(req)
      else:
        await req.respond(Http200, req.body.readAll)
    else:
      await req.respond(Http404, "Not found")

  asyncCheck server.serve(PORT, cb)
  runForever()

proc postRequest(path = "/", body = "*", count = 10_000_000): string =
  var s = newSocket()
  result = ""
  var left = body.len * count
  s.connect(HOST, PORT)
  s.send("POST " & path & " HTTP/1.0\c\L")
  s.send("Content-Type: application/octet-stream\c\L")
  s.send("Content-Length: " & $left & "\c\L\c\L")

  var buff = newSeq[char](if body.len == 1: 4096 else: body.len)
  if body.len == 1:
    for i in 0..<4096:
      buff[i] = body[0]
  else:
    for i in 0..<body.len:
      buff[i] = body[i]

  while left > 0:
    let cnt = if left < buff.len: left else: buff.len
    discard s.send(addr buff[0], cnt)
    left -= cnt

  var line = ""
  discard s.recv(line, 1024)
  result = line.splitLines[^1]

suite "asynchttpserver":

  spawn serverThread()

  let url = "http://" & HOST & ":" & $PORT.int

  test "GET":
    check: url.getContent == "Hello, world!"

  test "POST":
    check: url.postRequest(body = "Hi!", count = 1) == "Hi!"

  test "POST (count)":
    check: (url & "/count").postRequest(count = 2_000_000_000) == $2_000_000_000
