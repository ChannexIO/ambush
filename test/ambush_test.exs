defmodule AmbushTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  setup do
    {:ok, stub: Ambush.open()}
  end

  describe "expect/4" do
    test "answers the request with the handler", %{stub: stub} do
      Ambush.expect(stub, "GET", "/health", &send_resp(&1, 200, "ok"))

      assert {200, "ok"} = request(stub, :get, "/health")
      assert {200, "ok"} = request(stub, :get, "/health")
    end

    test "fails on exit when no request comes", %{stub: stub} do
      Ambush.expect(stub, "GET", "/health", &send_resp(&1, 200, "ok"))

      assert_raise ExUnit.AssertionError, ~r"expected GET /health at least once, got 0 call", fn ->
        Ambush.verify!(stub)
      end
    end

    test "sends a response that the handler only sets", %{stub: stub} do
      Ambush.expect(stub, "GET", "/set", &resp(&1, 201, "set"))

      assert {201, "set"} = request(stub, :get, "/set")
    end

    test "puts the path segments into path_params", %{stub: stub} do
      Ambush.expect(stub, "GET", "/users/:id/posts/:post", fn conn ->
        send_resp(conn, 200, "#{conn.path_params["id"]}:#{conn.path_params["post"]}")
      end)

      assert {200, "42:7"} = request(stub, :get, "/users/42/posts/7")
    end

    test "uses the newest route for the same method and path", %{stub: stub} do
      Ambush.expect(stub, "GET", "/a", &send_resp(&1, 200, "old"))
      Ambush.expect(stub, "GET", "/a", &send_resp(&1, 200, "new"))

      assert {200, "new"} = request(stub, :get, "/a")
    end

    test "answers with a static response tuple", %{stub: stub} do
      Ambush.expect(stub, "GET", "/static", {429, [{"retry-after", "30"}], "quota"})

      assert {429, "quota", headers} = request(stub, :get, "/static", [], "", :headers)
      assert {~c"retry-after", ~c"30"} in headers
    end
  end

  describe "expect/2" do
    test "matches any method and path", %{stub: stub} do
      Ambush.expect(stub, &send_resp(&1, 200, &1.method))

      assert {200, "DELETE"} = request(stub, :delete, "/anything")
    end

    test "matches only when no other route matches", %{stub: stub} do
      Ambush.expect(stub, &send_resp(&1, 200, "catch-all"))
      Ambush.expect(stub, "GET", "/exact", &send_resp(&1, 200, "exact"))

      assert {200, "exact"} = request(stub, :get, "/exact")
      assert {200, "catch-all"} = request(stub, :get, "/other")
    end
  end

  describe "expect/5 and expect_once/4" do
    test "fail on a call over the count", %{stub: stub} do
      Ambush.expect_once(stub, "POST", "/orders", &send_resp(&1, 201, ""))

      assert {201, ""} = request(stub, :post, "/orders")
      assert {500, _body} = request(stub, :post, "/orders")

      assert_raise ExUnit.AssertionError, ~r"expected POST /orders 1 time\(s\), got call 2", fn ->
        Ambush.verify!(stub)
      end
    end

    test "fail on a call under the count", %{stub: stub} do
      Ambush.expect(stub, "GET", "/poll", 3, &send_resp(&1, 200, ""))

      assert {200, ""} = request(stub, :get, "/poll")

      assert_raise ExUnit.AssertionError, ~r"expected GET /poll 3 time\(s\), got 1 call", fn ->
        Ambush.verify!(stub)
      end
    end
  end

  describe "expect_sequence/4" do
    test "answers the requests in order", %{stub: stub} do
      Ambush.expect_sequence(stub, "GET", "/retry", [{429, [], "slow"}, &send_resp(&1, 200, "ok")])

      assert {429, "slow"} = request(stub, :get, "/retry")
      assert {200, "ok"} = request(stub, :get, "/retry")
    end
  end

  describe ":close" do
    test "drops the connection without a reply and counts as a met call", %{stub: stub} do
      Ambush.expect_once(stub, "GET", "/drop", :close)

      assert {:error, :socket_closed_remotely} = raw_request(stub, :get, "/drop", [], "")
      assert :ok = Ambush.verify!(stub)
    end

    test "works inside a sequence", %{stub: stub} do
      Ambush.expect_sequence(stub, "GET", "/flaky", [:close, {200, [], "ok"}])

      assert {:error, :socket_closed_remotely} = raw_request(stub, :get, "/flaky", [], "")
      assert {200, "ok"} = request(stub, :get, "/flaky")
    end
  end

  describe "stub/4" do
    test "allows no request", %{stub: stub} do
      Ambush.stub(stub, "GET", "/config", &send_resp(&1, 200, ""))

      assert :ok = Ambush.verify!(stub)
    end
  end

  describe "unexpected requests" do
    test "answer 500 and fail on exit", %{stub: stub} do
      assert {500, body} = request(stub, :get, "/nothing")
      assert body =~ "unexpected request: GET /nothing"

      assert_raise ExUnit.AssertionError, ~r"unexpected request: GET /nothing", fn ->
        Ambush.verify!(stub)
      end
    end
  end

  describe "handler crashes" do
    test "re-raise the assertion of the handler on exit", %{stub: stub} do
      Ambush.expect(stub, "POST", "/check", fn conn ->
        assert conn.method == "GET"
        conn
      end)

      assert {500, _body} = request(stub, :post, "/check")

      assert_raise ExUnit.AssertionError, ~r"conn.method == \"GET\"", fn ->
        Ambush.verify!(stub)
      end
    end

    test "fail on a handler that does not return a conn", %{stub: stub} do
      Ambush.expect(stub, "GET", "/bad", fn _conn -> :oops end)

      assert {500, _body} = request(stub, :get, "/bad")

      assert_raise RuntimeError, ~r"returned :oops", fn ->
        Ambush.verify!(stub)
      end
    end
  end

  describe "requests/1" do
    test "logs every request, oldest first, with the body", %{stub: stub} do
      Ambush.stub(stub, "POST", "/messages", &send_resp(&1, 202, ""))

      request(stub, :post, "/messages?page=1", [{~c"x-key", ~c"1"}], "first")
      request(stub, :post, "/messages", [], "second")

      assert [first, second] = Ambush.requests(stub)
      assert %{method: "POST", path: "/messages", query: "page=1", body: "first"} = first
      assert {"x-key", "1"} in first.headers
      assert %{query: "", body: "second"} = second
    end

    test "lets the handler read the body again", %{stub: stub} do
      Ambush.expect(stub, "POST", "/echo", fn conn ->
        {:ok, body, conn} = read_body(conn)
        send_resp(conn, 200, body)
      end)

      assert {200, "payload"} = request(stub, :post, "/echo", [], "payload")
      assert [%{body: "payload"}] = Ambush.requests(stub)
    end

    test "lets the handler parse a form body", %{stub: stub} do
      parsers = Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"])

      Ambush.expect(stub, "POST", "/form", fn conn ->
        conn = Plug.Parsers.call(conn, parsers)
        send_resp(conn, 200, conn.body_params["name"])
      end)

      assert {200, "Alice"} = request(stub, :post, "/form", [], "name=Alice", ~c"application/x-www-form-urlencoded")
    end

    test "lets the handler parse a multipart upload", %{stub: stub} do
      parsers = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"])

      Ambush.expect(stub, "POST", "/upload", fn conn ->
        conn = Plug.Parsers.call(conn, parsers)
        %Plug.Upload{filename: filename, path: path} = conn.body_params["photo"]
        send_resp(conn, 200, "#{filename}:#{File.read!(path)}")
      end)

      body =
        Enum.join(
          [
            "--b",
            ~s(Content-Disposition: form-data; name="photo"; filename="a.jpg"),
            "Content-Type: image/jpeg",
            "",
            "jpeg-bytes",
            "--b--",
            ""
          ],
          "\r\n"
        )

      assert {200, "a.jpg:jpeg-bytes"} = request(stub, :post, "/upload", [], body, ~c"multipart/form-data; boundary=b")
    end
  end

  describe "down/1 and up/1" do
    test "refuse connections while down and keep the port", %{stub: stub} do
      Ambush.stub(stub, "GET", "/ping", &send_resp(&1, 200, "pong"))

      :ok = Ambush.down(stub)
      assert {:error, {:failed_connect, _reason}} = raw_request(stub, :get, "/ping", [], "")

      :ok = Ambush.up(stub)
      assert {200, "pong"} = request(stub, :get, "/ping")
    end
  end

  test "open/1 gives each stub its own port" do
    first = Ambush.open()
    second = Ambush.open()

    assert first.port != second.port
    assert Ambush.url(first, "/x") == "http://localhost:#{first.port}/x"
  end

  defp request(stub, method, path, headers \\ [], body \\ "", content_type \\ ~c"text/plain")

  defp request(stub, method, path, headers, body, :headers) do
    {:ok, {{_version, status, _reason}, resp_headers, resp_body}} = raw_request(stub, method, path, headers, body)
    {status, to_string(resp_body), resp_headers}
  end

  defp request(stub, method, path, headers, body, content_type) do
    {:ok, {{_version, status, _reason}, _headers, resp_body}} =
      raw_request(stub, method, path, headers, body, content_type)

    {status, to_string(resp_body)}
  end

  defp raw_request(stub, method, path, headers, body, content_type \\ ~c"text/plain") do
    url = to_charlist(Ambush.url(stub, path))
    headers = [{~c"connection", ~c"close"} | headers]
    request = if method in [:post, :put, :patch], do: {url, headers, content_type, body}, else: {url, headers}
    :httpc.request(method, request, [], [])
  end
end
