defmodule Ambush do
  @moduledoc """
  A local HTTP server for ExUnit tests, with the API of Bypass, on Bandit.

  `open/0` starts a server on a free port and adds an `on_exit` check. The
  check fails the test on an unmet expectation, an unexpected request, or a
  crash in a handler. Handlers get a real `Plug.Conn`, so `Plug.Parsers`
  works, and `requests/1` gives the log of every request.

  ## Routes

  A path can hold `:name` segments: `"/users/:id"` matches `"/users/42"` and
  sets `conn.path_params` to `%{"id" => "42"}`. A new route for the same
  method and path replaces the old one. A catch-all route from `expect/2`
  matches only when no other route matches.

  ## Responders

  A responder is a handler, `fn conn -> conn end`, a static
  `{status, headers, body}` tuple, or `:close`. A handler that sets a response
  with `Plug.Conn.resp/3` and does not send it gets it sent. `:close` drops the
  connection without a reply and counts as a met call.

  ## Example

      setup do
        {:ok, stub: Ambush.open()}
      end

      test "reads the user", %{stub: stub} do
        Ambush.expect_once(stub, "GET", "/users/:id", fn conn ->
          Plug.Conn.send_resp(conn, 200, ~s({"id":"\#{conn.path_params["id"]}"}))
        end)

        assert {:ok, %{"id" => "42"}} = MyClient.get_user(Ambush.url(stub), 42)
      end
  """

  alias Ambush.Instance

  @enforce_keys [:pid, :port]
  defstruct [:pid, :port]

  @type t() :: %__MODULE__{pid: pid(), port: :inet.port_number()}
  @type handler() :: (Plug.Conn.t() -> Plug.Conn.t())
  @type responder() :: handler() | {Plug.Conn.status(), Plug.Conn.headers(), iodata()} | :close
  @type request() :: %{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: Plug.Conn.headers(),
          body: binary()
        }

  @doc """
  Starts a stub on a free port, or on `:port`, and checks it when the test exits.
  Call it from the test process or from `setup`.
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    {:ok, pid} = DynamicSupervisor.start_child(Ambush.Supervisor, {Instance, opts})
    stub = %__MODULE__{pid: pid, port: Instance.port(pid)}
    ExUnit.Callbacks.on_exit({__MODULE__, pid}, fn -> verify!(stub) end)
    stub
  end

  @doc "Returns the base URL of the stub, with `path` appended."
  @spec url(t(), String.t()) :: String.t()
  def url(%__MODULE__{port: port}, path \\ ""), do: "http://localhost:#{port}#{path}"

  @doc "Expects one or more requests of any method to any path."
  @spec expect(t(), responder()) :: :ok
  def expect(stub, responder), do: add_route(stub, :any, :any, :at_least_once, responder)

  @doc "Expects one or more `method` requests to `path`."
  @spec expect(t(), String.t(), String.t(), responder()) :: :ok
  def expect(stub, method, path, responder), do: add_route(stub, method, path, :at_least_once, responder)

  @doc "Expects exactly `times` `method` requests to `path`."
  @spec expect(t(), String.t(), String.t(), pos_integer(), responder()) :: :ok
  def expect(stub, method, path, times, responder) when is_integer(times) and times > 0 do
    add_route(stub, method, path, times, responder)
  end

  @doc "Expects exactly one `method` request to `path`."
  @spec expect_once(t(), String.t(), String.t(), responder()) :: :ok
  def expect_once(stub, method, path, responder), do: add_route(stub, method, path, 1, responder)

  @doc """
  Expects one request to `path` for each responder, and answers them in order.
  Use it for retry tests: `[{429, [], ""}, :close, {200, [], "ok"}]`.
  """
  @spec expect_sequence(t(), String.t(), String.t(), [responder(), ...]) :: :ok
  def expect_sequence(stub, method, path, [_ | _] = responders) do
    add_route(stub, method, path, length(responders), {:sequence, responders})
  end

  @doc "Answers any number of `method` requests to `path`, also none."
  @spec stub(t(), String.t(), String.t(), responder()) :: :ok
  def stub(stub, method, path, responder), do: add_route(stub, method, path, :any, responder)

  @doc "Returns every request the stub got, oldest first."
  @spec requests(t()) :: [request()]
  def requests(%__MODULE__{pid: pid}), do: Instance.requests(pid)

  @doc "Closes the listener, so that a client gets `:econnrefused`. Routes stay."
  @spec down(t()) :: :ok
  def down(%__MODULE__{pid: pid}), do: Instance.down(pid)

  @doc "Opens the listener again on the same port."
  @spec up(t()) :: :ok
  def up(%__MODULE__{pid: pid}), do: Instance.up(pid)

  @doc """
  Stops the stub and raises on an unmet expectation, an unexpected request or
  a handler crash. `open/1` calls it on test exit. A second call does nothing.
  """
  @spec verify!(t()) :: :ok
  def verify!(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      errors = Instance.errors(pid)
      DynamicSupervisor.terminate_child(Ambush.Supervisor, pid)
      raise_errors(errors)
    end

    :ok
  end

  defp add_route(%__MODULE__{pid: pid}, method, path, times, responder) do
    route = %{
      method: method,
      path: path,
      segments: Instance.split_path(path),
      times: times,
      calls: 0,
      responder: responder
    }

    Instance.add_route(pid, route)
  end

  defp raise_errors([]), do: :ok

  # A handler crash keeps its own exception and stacktrace, so an assertion in
  # a handler fails the test with the usual ExUnit diff.
  defp raise_errors(errors) do
    case Enum.find(errors, &crash?/1) do
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      nil -> raise ExUnit.AssertionError, message: Enum.map_join(errors, "\n", &error_message/1)
    end
  end

  defp crash?({:message, _message}), do: false
  defp crash?(_error), do: true

  defp error_message({:message, message}), do: message
end
