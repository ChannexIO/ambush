defmodule Ambush.Plug do
  @moduledoc """
  The Bandit plug of a stub. It logs the request, asks `Ambush.Instance`
  for a route and runs its responder in the connection process.

  A request without a route, a call over the expected count and a crash in a
  handler get a 500 response. The instance keeps each as an error for
  `Ambush.verify!/1`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Ambush.CachedBody
  alias Ambush.Instance

  @impl true
  def init(instance), do: instance

  @impl true
  def call(conn, instance) do
    {body, conn} = read_full_body(conn, [])
    conn = CachedBody.wrap(conn, body)

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: conn.req_headers,
      body: body
    }

    conn =
      case Instance.match(instance, request) do
        {:ok, responder, path_params} -> respond(%{conn | path_params: path_params}, responder, instance)
        {:error, message} -> send_resp(conn, 500, message)
      end

    CachedBody.unwrap(conn)
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary([acc | chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc | chunk])
    end
  end

  # A kill skips the error handler of Bandit, which sends a 500 and logs the
  # error. The socket closes with the connection process, and nothing logs.
  defp respond(_conn, :close, _instance), do: Process.exit(self(), :kill)

  defp respond(conn, {status, headers, body}, _instance) do
    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
  end

  defp respond(conn, handler, instance) when is_function(handler, 1) do
    case handler.(conn) do
      %Plug.Conn{state: :set} = conn -> send_resp(conn)
      %Plug.Conn{} = conn -> conn
      other -> fail(conn, instance, :error, %RuntimeError{message: "Ambush handler returned #{inspect(other)}"}, [])
    end
  catch
    kind, reason -> fail(conn, instance, kind, reason, __STACKTRACE__)
  end

  defp fail(conn, instance, kind, reason, stacktrace) do
    Instance.record_error(instance, {kind, reason, stacktrace})
    send_resp(conn, 500, "Ambush handler failed: #{Exception.format_banner(kind, reason, stacktrace)}")
  end
end
