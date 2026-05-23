when not declared(newCurly):
  import curly
import std/[httpclient, json, net, strutils]

const RequestsToServe = 2

type ServerArgs = object
  server: Socket

proc readHeaderValue(line, name: string): string =
  let parts = line.split(":", 1)
  if parts.len == 2 and cmpIgnoreCase(parts[0], name) == 0:
    result = parts[1].strip()

proc handleClient(client: Socket) =
  let requestLine = client.recvLine(timeout = 5000)
  doAssert requestLine.startsWith("POST ")

  var contentLength = 0
  while true:
    let line = client.recvLine(timeout = 5000)
    if line == "" or line == "\c\L":
      break
    let value = readHeaderValue(line, "Content-Length")
    if value != "":
      contentLength = parseInt(value)

  var body: string
  if contentLength > 0:
    let bytesRead = client.recv(body, contentLength, timeout = 5000)
    doAssert bytesRead == contentLength

  let responseBody = $(%*{
    "received": body,
    "receivedLen": body.len
  })
  client.send(
    "HTTP/1.1 200 OK\c\L" &
    "Content-Type: application/json\c\L" &
    "Content-Length: " & $responseBody.len & "\c\L" &
    "Connection: close\c\L" &
    "\c\L" &
    responseBody
  )

proc serverThread(args: ServerArgs) {.thread.} =
  for _ in 0 ..< RequestsToServe:
    var client: owned(Socket)
    args.server.accept(client)
    try:
      handleClient(client)
    finally:
      client.close()
  args.server.close()

proc assertEchoedBody(responseBody, expected: string) =
  let parsed = parseJson(responseBody)
  doAssert parsed["received"].getStr() == expected
  doAssert parsed["receivedLen"].getInt() == expected.len

let server = newSocket()
server.setSockOpt(OptReuseAddr, true)
server.bindAddr(Port(0), "127.0.0.1")
server.listen()

let (_, port) = server.getLocalAddr()
let url = "http://127.0.0.1:" & $port & "/_auth/token/tokens"

var thread: Thread[ServerArgs]
createThread(thread, serverThread, ServerArgs(server: server))

let user = "test-user"
let passwd = "test-password"
let data = %*{
  "token": {
    "user": user,
    "password": passwd,
    "lifetime": "fixed"
  }
}
let expectedBody = $data

block stdHttpClientSendsPostBody:
  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  let response = client.post(url, body = expectedBody)
  doAssert response.code == Http200
  assertEchoedBody(response.body, expectedBody)

block curlySendsInlineJsonPostBody:
  let curl = newCurly()
  defer: curl.close()

  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/json"

  let response = curl.post(url, headers, body = $data)
  doAssert response.code == 200
  assertEchoedBody(response.body, expectedBody)

joinThread(thread)
