#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements a high performance asynchronous HTTP server.
##
## Examples
## --------
##
## This example will create an HTTP server on port 8080. The server will
## respond to all requests with a ``200 OK`` response code and "Hello World"
## as the response body.
##
## .. code-block::nim
##    import asynchttpserver, asyncdispatch
##
##    var server = newAsyncHttpServer()
##    proc cb(req: Request) {.async.} =
##      await req.respond(Http200, "Hello World")
##
##    waitFor server.serve(Port(8080), cb)

import tables, asyncnet, asyncdispatch, parseutils, uri, strutils, streams
import httpcore

export httpcore except parseHeader

# TODO: If it turns out that the decisions that asynchttpserver makes
# explicitly, about whether to close the client sockets or upgrade them are
# wrong, then add a return value which determines what to do for the callback.
# Also, maybe move `client` out of `Request` object and into the args for
# the proc.
type
  RequestBody* = ref object
    client: AsyncSocket
    length: int
    data: string

  Request* = object
    client*: AsyncSocket # TODO: Separate this into a Response object?
    reqMethod*: string
    headers*: HttpHeaders
    protocol*: tuple[orig: string, major, minor: int]
    url*: Uri
    hostname*: string ## The hostname of the client that made the request.
    body*: RequestBody

  AsyncHttpServer* = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool

{.deprecated: [TRequest: Request, PAsyncHttpServer: AsyncHttpServer,
  THttpCode: HttpCode, THttpVersion: HttpVersion].}

proc newAsyncHttpServer*(reuseAddr = true, reusePort = false): AsyncHttpServer =
  ## Creates a new ``AsyncHttpServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc len*(body: RequestBody): auto = body.length

proc readAll*(body: RequestBody): string =
  if body.data.isNil and not body.client.isNil:
    body.data = waitFor body.client.recv(body.len)
  result = body.data

type
  RequestBodyStream = ref RequestBodyStreamObj
  RequestBodyStreamObj = object of StreamObj
    body: RequestBody
    pos: int

proc rbClose(s: Stream) = s.RequestBodyStream.body.client.close
proc rbAtEnd(s: Stream): bool = s.RequestBodyStream.pos + 1 >= s.RequestBodyStream.body.length
proc rbSetPosition(s: Stream, pos: int) = raise newException(Exception, "Not implemented")
proc rbGetPosition(s: Stream): int = s.RequestBodyStream.pos
proc rbReadData(s: Stream, buff: pointer, buffLen: int): int =
  var ss = s.RequestBodyStream
  let toRead = if ss.pos + buffLen > ss.body.length: ss.body.length - ss.pos else: buffLen
  var str = waitFor ss.body.client.recv(toRead)
  result = str.len
  ss.pos += result
  copyMem(buff, addr str[0], result)
proc rbPeekData(s: Stream, buff: pointer, buffLen: int): int = raise newException(Exception, "Not implemented")
proc rbWriteData(s: Stream, buff: pointer, buffLen: int) = raise newException(Exception, "Not implemented")
proc rbFlush(s: Stream) = raise newException(Exception, "Not implemented")

proc getStream*(body: RequestBody): Stream =
  if not body.data.isNil:
    result = newStringStream(body.data)
  else:
    var rb = new RequestBodyStream
    rb.body = body
    rb.pos = 0
    rb.closeImpl = rbClose
    rb.atEndImpl = rbAtEnd
    rb.setPositionImpl = rbSetPosition
    rb.getPositionImpl = rbGetPosition
    rb.readDataImpl = cast[type(rb.readDataImpl)](rbReadData)
    rb.peekDataImpl = rbPeekData
    rb.writeDataImpl = rbWriteData
    rb.flushImpl = rbFlush

    result = rb

proc addHeaders(msg: var string, headers: HttpHeaders) =
  for k, v in headers:
    msg.add(k & ": " & v & "\c\L")

proc sendHeaders*(req: Request, headers: HttpHeaders): Future[void] =
  ## Sends the specified headers to the requesting client.
  var msg = ""
  addHeaders(msg, headers)
  return req.client.send(msg)

proc respond*(req: Request, code: HttpCode, content: string,
              headers: HttpHeaders = nil): Future[void] =
  ## Responds to the request with the specified ``HttpCode``, headers and
  ## content.
  ##
  ## This procedure will **not** close the client socket.
  var msg = "HTTP/1.1 " & $code & "\c\L"

  if headers != nil:
    msg.addHeaders(headers)
  msg.add("Content-Length: " & $content.len & "\c\L\c\L")
  msg.add(content)
  result = req.client.send(msg)

proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
  var i = protocol.skipIgnoreCase("HTTP/")
  if i != 5:
    raise newException(ValueError, "Invalid request protocol. Got: " &
        protocol)
  result.orig = protocol
  i.inc protocol.parseInt(result.major, i)
  i.inc # Skip .
  i.inc protocol.parseInt(result.minor, i)

proc sendStatus(client: AsyncSocket, status: string): Future[void] =
  client.send("HTTP/1.1 " & status & "\c\L")

proc processBody(client: AsyncSocket, length: int): RequestBody =
  new result
  result.length = length
  result.client = client

proc processClient(client: AsyncSocket, address: string,
                   callback: proc (request: Request):
                      Future[void] {.closure, gcsafe.}) {.async.} =
  var request: Request
  request.url = initUri()
  request.headers = newHttpHeaders()
  var lineFut = newFutureVar[string]("asynchttpserver.processClient")
  lineFut.mget() = newStringOfCap(80)
  var key, value = ""

  while not client.isClosed:
    # GET /path HTTP/1.1
    # Header: val
    # \n
    request.headers.clear()
    request.body = nil
    request.hostname.shallowCopy(address)
    assert client != nil
    request.client = client

    # First line - GET /path HTTP/1.1
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut) # TODO: Timeouts.
    if lineFut.mget == "":
      client.close()
      return

    var i = 0
    for linePart in lineFut.mget.split(' '):
      case i
      of 0: request.reqMethod.shallowCopy(linePart.normalize)
      of 1: parseUri(linePart, request.url)
      of 2:
        try:
          request.protocol = parseProtocol(linePart)
        except ValueError:
          asyncCheck request.respond(Http400,
            "Invalid request protocol. Got: " & linePart)
          continue
      else:
        await request.respond(Http400, "Invalid request. Got: " & lineFut.mget)
        continue
      inc i

    # Headers
    while true:
      i = 0
      lineFut.mget.setLen(0)
      lineFut.clean()
      await client.recvLineInto(lineFut)

      if lineFut.mget == "":
        client.close(); return
      if lineFut.mget == "\c\L": break
      let (key, value) = parseHeader(lineFut.mget)
      request.headers[key] = value
      # Ensure the client isn't trying to DoS us.
      if request.headers.len > headerLimit:
        await client.sendStatus("400 Bad Request")
        request.client.close()
        return

    if request.reqMethod == "post":
      # Check for Expect header
      if request.headers.hasKey("Expect"):
        if "100-continue" in request.headers["Expect"]:
          await client.sendStatus("100 Continue")
        else:
          await client.sendStatus("417 Expectation Failed")

    # Read the body
    # - Check for Content-length header
    if request.headers.hasKey("Content-Length"):
      var contentLength = 0
      if parseInt(request.headers["Content-Length"],
                  contentLength) == 0:
        await request.respond(Http400, "Bad Request. Invalid Content-Length.")
        continue
      else:
        request.body = processBody(client, contentLength)
    elif request.reqMethod == "post":
      await request.respond(Http400, "Bad Request. No Content-Length.")
      continue

    case request.reqMethod
    of "get", "post", "head", "put", "delete", "trace", "options",
       "connect", "patch":
      await callback(request)
    else:
      await request.respond(Http400, "Invalid request method. Got: " &
        request.reqMethod)

    if "upgrade" in request.headers.getOrDefault("connection"):
      return

    # Persistent connections
    if (request.protocol == HttpVer11 and
        request.headers.getOrDefault("connection").normalize != "close") or
       (request.protocol == HttpVer10 and
        request.headers.getOrDefault("connection").normalize == "keep-alive"):
      # In HTTP 1.1 we assume that connection is persistent. Unless connection
      # header states otherwise.
      # In HTTP 1.0 we assume that the connection should not be persistent.
      # Unless the connection header states otherwise.
      discard
    else:
      request.client.close()
      break

proc serve*(server: AsyncHttpServer, port: Port,
            callback: proc (request: Request): Future[void] {.closure,gcsafe.},
            address = "") {.async.} =
  ## Starts the process of listening for incoming HTTP connections on the
  ## specified address and port.
  ##
  ## When a request is made by a client the specified callback will be called.
  server.socket = newAsyncSocket()
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    # TODO: Causes compiler crash.
    #var (address, client) = await server.socket.acceptAddr()
    var fut = await server.socket.acceptAddr()
    asyncCheck processClient(fut.client, fut.address, callback)
    #echo(f.isNil)
    #echo(f.repr)

proc close*(server: AsyncHttpServer) =
  ## Terminates the async http server instance.
  server.socket.close()

when not defined(testing) and isMainModule:
  proc main =
    var server = newAsyncHttpServer()
    proc cb(req: Request) {.async.} =
      #echo(req.reqMethod, " ", req.url)
      #echo(req.headers)
      let headers = {"Date": "Tue, 29 Apr 2014 23:40:08 GMT",
          "Content-type": "text/plain; charset=utf-8"}
      await req.respond(Http200, "Hello World", headers.newHttpHeaders())

    asyncCheck server.serve(Port(5555), cb)
    runForever()
  main()
