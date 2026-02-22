defmodule JidoCodeServer.Project.Policy do
  @moduledoc """
  Project-scoped sandbox and authorization policy.
  """

  use GenServer

  alias JidoCodeServer.Telemetry

  @max_decisions 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    allow_tools =
      opts
      |> Keyword.get(:allow_tools)
      |> normalize_tool_set()

    deny_tools =
      opts
      |> Keyword.get(:deny_tools, [])
      |> normalize_tool_set()

    state = %{
      project_id: Keyword.get(opts, :project_id),
      root_path: Keyword.get(opts, :root_path),
      allow_tools: allow_tools,
      deny_tools: deny_tools,
      recent_decisions: []
    }

    {:ok, state}
  end

  @spec normalize_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside_root | :invalid_root_path}
  def normalize_path(root_path, user_path) do
    root = root_path |> Path.expand() |> resolve_symlinks()
    candidate = expand_user_path(user_path, root)
    resolved = resolve_symlinks(candidate)

    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        if inside_root?(root, resolved) do
          {:ok, resolved}
        else
          {:error, :outside_root}
        end

      _ ->
        {:error, :invalid_root_path}
    end
  end

  @spec authorize_tool(GenServer.server(), String.t(), map(), map()) ::
          :ok | {:error, :denied | :outside_root | term()}
  def authorize_tool(server, tool_name, args, ctx)
      when is_binary(tool_name) and is_map(args) and is_map(ctx) do
    authorize_tool(server, tool_name, args, %{}, ctx)
  end

  @spec authorize_tool(GenServer.server(), String.t(), map(), map(), map()) ::
          :ok | {:error, :denied | :outside_root | term()}
  def authorize_tool(server, tool_name, args, meta, ctx)
      when is_binary(tool_name) and is_map(args) and is_map(meta) and is_map(ctx) do
    GenServer.call(server, {:authorize_tool, tool_name, args, meta, ctx})
  end

  @spec filter_tools(GenServer.server(), list(map())) :: list(map())
  def filter_tools(server, tool_specs) when is_list(tool_specs) do
    GenServer.call(server, {:filter_tools, tool_specs})
  end

  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(server) do
    GenServer.call(server, :diagnostics)
  end

  @impl true
  def handle_call({:authorize_tool, tool_name, args, meta, ctx}, _from, state) do
    {reply, reason} =
      case authorize_with_reason(state, tool_name, args) do
        :ok ->
          {:ok, :allowed}

        {:error, denied_reason} ->
          {{:error, denied_reason}, denied_reason}
      end

    decision = %{
      project_id: state.project_id || Map.get(ctx, :project_id),
      conversation_id: extract_conversation_id(meta, ctx),
      tool_name: tool_name,
      reason: reason,
      decision: if(reply == :ok, do: :allow, else: :deny),
      at: DateTime.utc_now()
    }

    emit_policy_decision(decision)
    {:reply, reply, store_decision(state, decision)}
  end

  def handle_call({:filter_tools, tool_specs}, _from, state) do
    filtered =
      Enum.filter(tool_specs, fn spec ->
        spec_name = Map.get(spec, :name) || Map.get(spec, "name")
        is_binary(spec_name) and tool_allowed?(state, spec_name)
      end)

    {:reply, filtered, state}
  end

  def handle_call(:diagnostics, _from, state) do
    diagnostics = %{
      project_id: state.project_id,
      root_path: state.root_path,
      allow_tools: tool_set_to_list(state.allow_tools),
      deny_tools: tool_set_to_list(state.deny_tools),
      recent_decisions: state.recent_decisions
    }

    {:reply, diagnostics, state}
  end

  defp validate_arg_paths(nil, _args), do: :ok

  defp validate_arg_paths(root_path, args) when is_map(args) do
    args
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn
      {key, value}, :ok when is_binary(key) ->
        maybe_validate_path(root_path, key, value)

      {key, value}, :ok when is_atom(key) ->
        maybe_validate_path(root_path, Atom.to_string(key), value)

      {_key, _value}, :ok ->
        {:cont, :ok}
    end)
  end

  defp maybe_validate_path(root_path, key, value) when is_binary(value) do
    if String.contains?(String.downcase(key), "path") do
      case normalize_path(root_path, value) do
        {:ok, _resolved} -> {:cont, :ok}
        {:error, :outside_root} -> {:halt, {:error, :outside_root}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, :ok}
    end
  end

  defp maybe_validate_path(_root_path, _key, _value), do: {:cont, :ok}

  defp authorize_with_reason(state, tool_name, args) do
    if tool_allowed?(state, tool_name) do
      validate_arg_paths(state.root_path, args)
    else
      {:error, :denied}
    end
  end

  defp normalize_tool_set(nil), do: nil

  defp normalize_tool_set(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_tool_set(_other), do: MapSet.new()

  defp tool_set_to_list(nil), do: []

  defp tool_set_to_list(set) do
    set
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp tool_allowed?(state, tool_name) do
    denied = MapSet.member?(state.deny_tools, tool_name)

    allowed =
      case state.allow_tools do
        nil -> true
        set -> MapSet.member?(set, tool_name)
      end

    not denied and allowed
  end

  defp inside_root?(root, path) do
    relative = Path.relative_to(path, root)

    case :filelib.safe_relative_path(relative, ".") do
      :unsafe -> false
      _safe -> true
    end
  end

  defp expand_user_path(user_path, root) do
    case Path.type(user_path) do
      :absolute -> Path.expand(user_path)
      _ -> Path.expand(user_path, root)
    end
  end

  defp resolve_symlinks(path) do
    absolute = Path.expand(path)

    case Path.split(absolute) do
      [] ->
        absolute

      [head | tail] ->
        Enum.reduce(tail, head, fn segment, current ->
          current
          |> Path.join(segment)
          |> resolve_segment()
        end)
    end
  end

  defp resolve_segment(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_link(path)

      _ ->
        path
    end
  end

  defp resolve_link(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target_chars} ->
        expand_link_target(path, List.to_string(target_chars))

      {:error, _reason} ->
        path
    end
  end

  defp expand_link_target(path, target) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      _ -> Path.expand(target, Path.dirname(path))
    end
  end

  defp store_decision(state, decision) do
    recent_decisions =
      [decision | state.recent_decisions]
      |> Enum.take(@max_decisions)

    %{state | recent_decisions: recent_decisions}
  end

  defp emit_policy_decision(decision) do
    case decision.decision do
      :allow ->
        Telemetry.emit("policy.allowed", decision)

      :deny ->
        Telemetry.emit("policy.denied", decision)
        maybe_emit_security_signal(decision)
    end
  end

  defp maybe_emit_security_signal(%{reason: :outside_root} = decision) do
    Telemetry.emit("security.sandbox_violation", decision)
  end

  defp maybe_emit_security_signal(_decision), do: :ok

  defp extract_conversation_id(meta, ctx) do
    Map.get(meta, :conversation_id) ||
      Map.get(meta, "conversation_id") ||
      Map.get(ctx, :conversation_id) ||
      Map.get(ctx, "conversation_id")
  end
end
