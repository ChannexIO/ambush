defmodule Ambush.Instance do
  @moduledoc """
  The state of one stub: the Bandit listener, the routes, the request log
  and the errors that `Ambush.verify!/1` reports.

  `Ambush.Plug` asks `match/2` for a route and then runs the handler in the
  connection process, so a slow handler does not block other requests.
  Each match counts as a call, also when the handler crashes later.
  """

  use GenServer, restart: :temporary

  @type route() :: %{
          method: String.t() | :any,
          path: String.t() | :any,
          segments: [String.t()] | :any,
          times: pos_integer() | :at_least_once | :any,
          calls: non_neg_integer(),
          responder: Ambush.responder() | {:sequence, [Ambush.responder()]}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec port(pid()) :: :inet.port_number()
  def port(pid), do: GenServer.call(pid, :port)

  @spec add_route(pid(), route()) :: :ok
  def add_route(pid, route), do: GenServer.call(pid, {:add_route, route})

  @spec match(pid(), Ambush.request()) :: {:ok, Ambush.responder(), map()} | {:error, String.t()}
  def match(pid, request), do: GenServer.call(pid, {:match, request})

  @spec record_error(pid(), {:error | :exit | :throw, term(), Exception.stacktrace()}) :: :ok
  def record_error(pid, error), do: GenServer.cast(pid, {:record_error, error})

  @spec requests(pid()) :: [Ambush.request()]
  def requests(pid), do: GenServer.call(pid, :requests)

  @spec down(pid()) :: :ok
  def down(pid), do: GenServer.call(pid, :down)

  @spec up(pid()) :: :ok
  def up(pid), do: GenServer.call(pid, :up)

  @spec errors(pid()) :: [term()]
  def errors(pid), do: GenServer.call(pid, :errors)

  @impl true
  def init(opts) do
    state = %{port: Keyword.get(opts, :port, 0), server: nil, routes: [], requests: [], errors: []}
    {:ok, start_server(state)}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:add_route, route}, _from, state) do
    routes = Enum.reject(state.routes, &same_route?(&1, route))
    {:reply, :ok, %{state | routes: sort_routes([route | routes])}}
  end

  def handle_call({:match, request}, _from, state) do
    state = %{state | requests: [request | state.requests]}

    case find_route(state.routes, request) do
      nil ->
        message = "Ambush got an unexpected request: #{request.method} #{request.path}"
        {:reply, {:error, message}, %{state | errors: [{:message, message} | state.errors]}}

      {index, route, path_params} ->
        call_route(state, index, %{route | calls: route.calls + 1}, path_params)
    end
  end

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call(:down, _from, state), do: {:reply, :ok, stop_server(state)}

  def handle_call(:up, _from, %{server: nil} = state), do: {:reply, :ok, start_server(state)}
  def handle_call(:up, _from, state), do: {:reply, :ok, state}

  def handle_call(:errors, _from, state) do
    unmet =
      state.routes
      |> Enum.filter(&unmet?/1)
      |> Enum.map(&unmet_error/1)

    {:reply, Enum.reverse(state.errors, unmet), state}
  end

  @impl true
  def handle_cast({:record_error, error}, state), do: {:noreply, %{state | errors: [error | state.errors]}}

  @impl true
  def terminate(_reason, state), do: stop_server(state)

  defp call_route(state, index, %{times: times, calls: calls} = route, _path_params)
       when is_integer(times) and calls > times do
    message =
      "Ambush expected #{route.method} #{route.path} #{times} time(s), " <>
        "got call #{calls}"

    state = %{state | routes: List.replace_at(state.routes, index, route), errors: [{:message, message} | state.errors]}
    {:reply, {:error, message}, state}
  end

  defp call_route(state, index, route, path_params) do
    state = %{state | routes: List.replace_at(state.routes, index, route)}
    {:reply, {:ok, responder(route), path_params}, state}
  end

  defp responder(%{responder: {:sequence, responders}, calls: calls}), do: Enum.at(responders, calls - 1)
  defp responder(%{responder: responder}), do: responder

  defp find_route(routes, request) do
    segments = split_path(request.path)

    routes
    |> Enum.with_index()
    |> Enum.find_value(&match_route(&1, request.method, segments))
  end

  defp match_route({%{method: method} = route, index}, request_method, segments)
       when method in [:any, request_method] do
    case match_segments(route.segments, segments, %{}) do
      nil -> nil
      path_params -> {index, route, path_params}
    end
  end

  defp match_route(_route_with_index, _method, _segments), do: nil

  defp match_segments(:any, _segments, params), do: params
  defp match_segments([], [], params), do: params

  defp match_segments([":" <> name | pattern], [value | rest], params) do
    match_segments(pattern, rest, Map.put(params, name, value))
  end

  defp match_segments([same | pattern], [same | rest], params), do: match_segments(pattern, rest, params)
  defp match_segments(_pattern, _segments, _params), do: nil

  @doc false
  @spec split_path(String.t() | :any) :: [String.t()] | :any
  def split_path(:any), do: :any
  def split_path(path), do: String.split(path, "/", trim: true)

  # A catch-all route from `Ambush.expect/2` matches only when no other route
  # matches. `Enum.sort_by/2` is stable, so the newest route still wins.
  defp sort_routes(routes), do: Enum.sort_by(routes, &catch_all?/1)

  defp catch_all?(route), do: route.path == :any

  defp same_route?(left, right), do: left.method == right.method and left.path == right.path

  defp unmet?(%{times: :at_least_once, calls: 0}), do: true
  defp unmet?(%{times: times, calls: calls}) when is_integer(times), do: calls < times
  defp unmet?(_route), do: false

  defp unmet_error(route) do
    expected = if route.times == :at_least_once, do: "at least once", else: "#{route.times} time(s)"
    {:message, "Ambush expected #{route.method} #{route.path} #{expected}, got #{route.calls} call(s)"}
  end

  defp start_server(state) do
    {:ok, server} =
      Bandit.start_link(
        plug: {Ambush.Plug, self()},
        ip: :loopback,
        port: state.port,
        startup_log: false,
        thousand_island_options: [num_acceptors: 2]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{state | server: server, port: port}
  end

  defp stop_server(%{server: nil} = state), do: state

  defp stop_server(state) do
    ThousandIsland.stop(state.server, 1_000)
    %{state | server: nil}
  end
end
