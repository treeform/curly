import
  std/[net, os],
  curly

proc testConnectionFailure() =
  ## Preserves streamed connection errors after their native request is freed.
  let names = ["NO_PROXY", "no_proxy"]
  var previous: array[2, tuple[present: bool, value: string]]
  for i, name in names:
    previous[i] = (existsEnv(name), getEnv(name))
    putEnv(name, "127.0.0.1")
  defer:
    for i, name in names:
      if previous[i].present:
        putEnv(name, previous[i].value)
      else:
        delEnv(name)
  let
    reservation = newSocket()
    curl = newCurly(maxInFlight = 1)
  defer:
    curl.close()
    reservation.close()
  reservation.bindAddr(Port(0), "127.0.0.1")
  let url = "http://127.0.0.1:" & $reservation.getLocalAddr()[1] & "/"
  for attempt in 0 ..< 3:
    var failed = false
    try:
      let stream = curl.request("GET", url, timeout = 2)
      stream.close()
    except CatchableError as error:
      failed = true
      doAssert error.msg.len > 0,
        "A failed streamed request must retain its original error message."
    doAssert failed, "The reserved port does not accept connections."

testConnectionFailure()
echo "Streamed connection failure tests passed without external requests."
