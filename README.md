# Ambush

A local HTTP server for ExUnit tests, with the API of Bypass, on Bandit.
Use it to test an HTTP client against real wire traffic.

## Install

```elixir
{:ambush, github: "ChannexIO/ambush", tag: "v0.1.0", only: :test}
```

Elixir `~> 1.18`. Runtime deps: `bandit`, `plug`.

## Use

```elixir
setup do
  {:ok, stub: Ambush.open()}
end

test "retries a 429", %{stub: stub} do
  Ambush.expect_sequence(stub, "POST", "/messages", [
    {429, [{"retry-after", "1"}], ""},
    {200, [], ~s({"ok":true})}
  ])

  assert {:ok, _} = MyClient.send_message(Ambush.url(stub), "hi")
  assert [%{body: ~s({"text":"hi"})}, _retry] = Ambush.requests(stub)
end
```

| Function | Expects |
| --- | --- |
| `expect(stub, responder)` | one or more requests to any route |
| `expect(stub, method, path, responder)` | one or more requests |
| `expect(stub, method, path, times, responder)` | exactly `times` requests |
| `expect_once(stub, method, path, responder)` | exactly one request |
| `expect_sequence(stub, method, path, responders)` | one request for each responder, in order |
| `stub(stub, method, path, responder)` | any number of requests, also none |

A responder is `fn conn -> conn end`, a `{status, headers, body}` tuple, or
`:close`. `:close` drops the connection without a reply, to test how a client
handles a lost connection. It counts as a met call.
A path can hold `:name` segments, which go into `conn.path_params`.
`down/1` and `up/1` close and open the listener on the same port.

## The exit check

`open/1` adds an `on_exit` that calls `verify!/1`. The test fails when:

- an expectation got fewer calls than it expects,
- a request matched no route, or matched a route over its count,
- a handler raised. The test fails with the handler's own exception, so an
  `assert` in a handler shows the usual ExUnit diff.

Each of these requests gets a 500 response at once.

## Differences from Bypass

- Handlers get a real `Plug.Conn`, so `Plug.Parsers` and multipart work.
- `requests/1` logs every request with its body. A handler can still read
  the body again.
- `expect_sequence/4` and `expect/5` with an exact count.
- `:close` replaces `pass/1`. A call counts when its route matches, so a
  handler never needs to mark a request as handled.
- ExUnit only. Bypass also supports ESpec.
