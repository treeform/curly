import std/[atomics, net, strutils], curly

var
  ports: Channel[int]
  unreadRequests: Atomic[int]

proc serve() {.thread.} =
  ## Serves local responses and counts queued requests completed during close.
  let server = newSocket()
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  ports.send(server.getLocalAddr()[1].int)
  while true:
    var socket: Socket
    server.accept(socket)
    let first = socket.recvLine(timeout = 3000)
    if first.contains("/stop"):
      socket.close()
      break
    while true:
      let line = socket.recvLine(timeout = 3000)
      if line.len == 0 or line == "\r\n":
        break
    if not first.contains("/drop"):
      if first.contains(" /unread "):
        discard unreadRequests.fetchAdd(1, moRelaxed)
      let body = repeat("response survives close;", 100)
      socket.send("HTTP/1.1 201 Created\r\nContent-Length: " & $body.len &
        "\r\nConnection: close\r\nX-Lifetime: retained\r\n\r\n" & body)
    socket.close()
  server.close()
  ports.close()
  reset(ports)

proc verify(response: var Response, url, expected: string) =
  ## Reads and reallocates the response after its worker allocator is gone.
  doAssert response.code == 201
  doAssert response.url == url
  doAssert response.body == expected
  doAssert response.headers["X-Lifetime"] == "retained"
  response.url.add repeat("!", 2000)
  response.body.add repeat("!", 5000)

ports.open()
var server: Thread[void]
createThread(server, serve)
let
  port = ports.recv()
  baseUrl = "http://127.0.0.1:" & $port
  url = baseUrl & "/body"
  expected = repeat("response survives close;", 100)

for i in 0 ..< 20:
  block:
    let curl = newCurly(1)
    var response = curl.get(url)
    curl.close()
    response.verify(url, expected)
  block:
    let curl = newCurly(1)
    var batch: RequestBatch
    batch.get(url)
    curl.startRequests(batch)
    var response = curl.waitForResponse()
    curl.close()
    doAssert response.error.len == 0
    response.response.verify(url, expected)
  block:
    let curl = newCurly(1)
    var body: string
    var stream = curl.request("GET", url)
    while stream.read(body) > 0:
      discard
    stream.close()
    curl.close()
    doAssert stream.code == 201
    doAssert stream.url == url
    doAssert body == expected
    stream.url.add repeat("!", 2000)
    body.add repeat("!", 5000)
  block:
    let curl = newCurly(1)
    var error: string
    try:
      discard curl.get(baseUrl & "/drop")
    except CatchableError:
      error = getCurrentExceptionMsg()
    curl.close()
    doAssert error.len > 0
    error.add repeat("!", 5000)
  block:
    let curl = newCurly(1)
    var error: string
    try:
      let stream = curl.request("GET", baseUrl & "/drop")
      stream.close()
    except CatchableError:
      error = getCurrentExceptionMsg()
    curl.close()
    doAssert error.len > 0
    error.add repeat("!", 5000)
  block:
    let
      curl = newCurly(1)
      previousRequests = unreadRequests.load(moRelaxed)
    var batch: RequestBatch
    for j in 0 ..< 4:
      batch.get(baseUrl & "/unread")
    curl.startRequests(batch)
    # Close must finish queued requests and free unread responses on its worker.
    curl.close()
    doAssert unreadRequests.load(moRelaxed) == previousRequests + 4
  block:
    let
      curl = newCurly(0)
      previousRequests = unreadRequests.load(moRelaxed)
    curl.startRequest("GET", baseUrl & "/unread")
    curl.close()
    doAssert unreadRequests.load(moRelaxed) == previousRequests

let stop = newSocket()
stop.connect("127.0.0.1", Port(port))
stop.send("GET /stop HTTP/1.1\r\n\r\n")
stop.close()
joinThread(server)
echo "Curly retained responses and unread cleanup passed (140 lifecycles)"
