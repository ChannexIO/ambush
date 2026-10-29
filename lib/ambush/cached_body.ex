defmodule Ambush.CachedBody do
  @moduledoc """
  A `Plug.Conn.Adapter` that serves a request body that was already read.

  `Ambush.Plug` reads the body once for the request log. This adapter wraps
  the server adapter, so a handler can read the same body again, for example
  through `Plug.Parsers`. Every other callback goes to the server adapter.
  `unwrap/1` gives the server adapter back before the conn returns to Bandit.
  """

  @behaviour Plug.Conn.Adapter

  @doc "Wraps the adapter of `conn` so that the next reads return `body`."
  @spec wrap(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def wrap(%Plug.Conn{adapter: {mod, payload}} = conn, body) do
    %{conn | adapter: {__MODULE__, %{mod: mod, payload: payload, body: body}}}
  end

  @doc "Puts the server adapter back into `conn`."
  @spec unwrap(Plug.Conn.t()) :: Plug.Conn.t()
  def unwrap(%Plug.Conn{adapter: {__MODULE__, %{mod: mod, payload: payload}}} = conn) do
    %{conn | adapter: {mod, payload}}
  end

  def unwrap(conn), do: conn

  @impl true
  def read_req_body(%{body: body} = state, opts) do
    length = Keyword.get(opts, :length, 8_000_000)

    case body do
      <<chunk::binary-size(^length), rest::binary>> when rest != "" -> {:more, chunk, %{state | body: rest}}
      chunk -> {:ok, chunk, %{state | body: ""}}
    end
  end

  @impl true
  def send_resp(state, status, headers, body), do: forward(state, :send_resp, [status, headers, body])

  @impl true
  def send_file(state, status, headers, path, offset, length) do
    forward(state, :send_file, [status, headers, path, offset, length])
  end

  @impl true
  def send_chunked(state, status, headers), do: forward(state, :send_chunked, [status, headers])

  @impl true
  def chunk(state, body), do: forward(state, :chunk, [body])

  @impl true
  def inform(state, status, headers), do: forward(state, :inform, [status, headers])

  @impl true
  def upgrade(state, protocol, opts), do: forward(state, :upgrade, [protocol, opts])

  @impl true
  def push(state, path, headers), do: forward(state, :push, [path, headers])

  @impl true
  def get_peer_data(%{mod: mod, payload: payload}), do: mod.get_peer_data(payload)

  @impl true
  def get_sock_data(%{mod: mod, payload: payload}), do: mod.get_sock_data(payload)

  @impl true
  def get_ssl_data(%{mod: mod, payload: payload}), do: mod.get_ssl_data(payload)

  @impl true
  def get_http_protocol(%{mod: mod, payload: payload}), do: mod.get_http_protocol(payload)

  # The server adapter returns a new payload in different tuple shapes.
  # Put it back into the wrapper, and pass every other result through.
  defp forward(%{mod: mod, payload: payload} = state, fun, args) do
    case apply(mod, fun, [payload | args]) do
      {:ok, sent_body, payload} -> {:ok, sent_body, %{state | payload: payload}}
      {:ok, payload} -> {:ok, %{state | payload: payload}}
      other -> other
    end
  end
end
