defmodule Jido.Code.Server.Project.Policy do
  @moduledoc """
  Project-scoped sandbox and authorization policy.
  """

  use GenServer

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Telemetry

  @max_decisions 200
  @opaque_url_pattern ~r/(?:^|[^A-Za-z0-9+.\-])([A-Za-z][A-Za-z0-9+\-.]{1,20}:\/\/[^\s"'<>()[\]{}]+)/u
  @opaque_keyed_value_pattern ~r/(url|uri|host|domain|endpoint)\s*(?:=|:|=>)\s*["']?([^\s"',}>]+)/iu

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    root_path = Keyword.get(opts, :root_path)

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
      root_path: root_path,
      allow_tools: allow_tools,
      deny_tools: deny_tools,
      network_egress_policy: normalize_network_policy(Keyword.get(opts, :network_egress_policy)),
      network_allowlist: normalize_network_allowlist(Keyword.get(opts, :network_allowlist, [])),
      network_allowed_schemes:
        normalize_network_schemes(
          Keyword.get(opts, :network_allowed_schemes, Config.network_allowed_schemes())
        ),
      sensitive_path_denylist:
        normalize_path_patterns(
          Keyword.get(opts, :sensitive_path_denylist, Config.sensitive_path_denylist())
        ),
      sensitive_path_allowlist:
        normalize_path_patterns(
          Keyword.get(opts, :sensitive_path_allowlist, Config.sensitive_path_allowlist())
        ),
      outside_root_allowlist:
        normalize_outside_root_allowlist(
          Keyword.get(opts, :outside_root_allowlist, Config.outside_root_allowlist()),
          root_path
        ),
      recent_decisions: []
    }

    {:ok, state}
  end

  @spec normalize_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside_root | :invalid_root_path}
  def normalize_path(root_path, user_path) do
    case resolve_path(root_path, user_path) do
      {:ok, root, resolved} ->
        if inside_root?(root, resolved) do
          {:ok, resolved}
        else
          {:error, :outside_root}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec authorize_tool(GenServer.server(), String.t(), map(), map()) ::
          :ok
          | {:error,
             :denied
             | :outside_root
             | :network_denied
             | :network_endpoint_denied
             | :network_protocol_denied
             | :sensitive_path_denied
             | term()}
  def authorize_tool(server, tool_name, args, ctx)
      when is_binary(tool_name) and is_map(args) and is_map(ctx) do
    authorize_tool(server, tool_name, args, %{}, ctx)
  end

  @spec authorize_tool(GenServer.server(), String.t(), map(), map(), map()) ::
          :ok
          | {:error,
             :denied
             | :outside_root
             | :network_denied
             | :network_endpoint_denied
             | :network_protocol_denied
             | :sensitive_path_denied
             | term()}
  def authorize_tool(server, tool_name, args, meta, ctx)
      when is_binary(tool_name) and is_map(args) and is_map(meta) and is_map(ctx) do
    authorize_tool(server, tool_name, args, meta, %{}, ctx)
  end

  @spec authorize_tool(GenServer.server(), String.t(), map(), map(), map(), map()) ::
          :ok
          | {:error,
             :denied
             | :outside_root
             | :network_denied
             | :network_endpoint_denied
             | :network_protocol_denied
             | :sensitive_path_denied
             | term()}
  def authorize_tool(server, tool_name, args, meta, tool_safety, ctx)
      when is_binary(tool_name) and is_map(args) and is_map(meta) and is_map(tool_safety) and
             is_map(ctx) do
    GenServer.call(server, {:authorize_tool, tool_name, args, meta, tool_safety, ctx})
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
  def handle_call({:authorize_tool, tool_name, args, meta, tool_safety, ctx}, _from, state) do
    {reply, reason, authorization_meta} =
      case authorize_with_reason(state, tool_name, args, tool_safety) do
        {:ok, authorization_meta} ->
          {:ok, :allowed, authorization_meta}

        {:error, denied_reason} ->
          {{:error, denied_reason}, denied_reason, default_authorization_meta()}
      end

    outside_root_exception_reason_codes =
      Map.get(authorization_meta, :outside_root_exception_reason_codes, [])

    decision = %{
      project_id: state.project_id || Map.get(ctx, :project_id),
      conversation_id: extract_conversation_id(meta, ctx),
      correlation_id: extract_correlation_id(meta, ctx),
      tool_name: tool_name,
      reason: reason,
      decision: if(reply == :ok, do: :allow, else: :deny),
      outside_root_exception_reason_codes: outside_root_exception_reason_codes,
      at: DateTime.utc_now()
    }

    emit_policy_decision(decision)
    {:reply, reply, store_decision(state, decision)}
  end

  def handle_call({:filter_tools, tool_specs}, _from, state) do
    filtered =
      Enum.filter(tool_specs, fn spec ->
        spec_name = Map.get(spec, :name) || Map.get(spec, "name")

        is_binary(spec_name) and tool_allowed?(state, spec_name) and
          tool_visible_under_network_policy?(state, spec)
      end)

    {:reply, filtered, state}
  end

  def handle_call(:diagnostics, _from, state) do
    diagnostics = %{
      project_id: state.project_id,
      root_path: state.root_path,
      allow_tools: tool_set_to_list(state.allow_tools),
      deny_tools: tool_set_to_list(state.deny_tools),
      network_egress_policy: state.network_egress_policy,
      network_allowlist: state.network_allowlist,
      network_allowed_schemes: state.network_allowed_schemes,
      sensitive_path_denylist: state.sensitive_path_denylist,
      sensitive_path_allowlist: state.sensitive_path_allowlist,
      outside_root_allowlist: state.outside_root_allowlist,
      recent_decisions: state.recent_decisions
    }

    {:reply, diagnostics, state}
  end

  defp validate_arg_paths(%{root_path: nil}, _args), do: {:ok, default_authorization_meta()}

  defp validate_arg_paths(state, args) when is_map(state) and is_map(args) do
    result =
      args
      |> Map.to_list()
      |> Enum.reduce_while(default_authorization_meta(), fn
        {key, value}, acc when is_binary(key) ->
          maybe_validate_path(state, key, value, acc)

        {key, value}, acc when is_atom(key) ->
          maybe_validate_path(state, Atom.to_string(key), value, acc)

        {_key, _value}, acc ->
          {:cont, acc}
      end)

    case result do
      {:error, _reason} = error -> error
      authorization_meta -> {:ok, authorization_meta}
    end
  end

  defp maybe_validate_path(state, key, value, authorization_meta) when is_binary(value) do
    if String.contains?(String.downcase(key), "path") do
      case validate_path_arg(state, value) do
        {:ok, reason_code} ->
          {:cont, put_outside_root_reason_code(authorization_meta, reason_code)}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    else
      {:cont, authorization_meta}
    end
  end

  defp maybe_validate_path(_state, _key, _value, authorization_meta),
    do: {:cont, authorization_meta}

  defp validate_path_arg(state, value) do
    case normalize_path(state.root_path, value) do
      {:ok, resolved} ->
        case validate_sensitive_path(state, resolved) do
          :ok -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end

      {:error, :outside_root} ->
        maybe_allow_outside_root_path(state, value)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_allow_outside_root_path(state, value) do
    with {:ok, _root, resolved} <- resolve_path(state.root_path, value),
         {:ok, reason_code} <- outside_root_reason_code(state.outside_root_allowlist, resolved) do
      {:ok, reason_code}
    else
      {:error, :outside_root} -> {:error, :outside_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp outside_root_reason_code(allowlist, resolved_path) when is_list(allowlist) do
    normalized_path = String.replace(resolved_path, "\\", "/")

    case Enum.find(allowlist, fn entry ->
           outside_root_allowlist_match?(entry, normalized_path)
         end) do
      %{reason_code: reason_code} ->
        {:ok, reason_code}

      _ ->
        {:error, :outside_root}
    end
  end

  defp outside_root_reason_code(_allowlist, _resolved_path), do: {:error, :outside_root}

  defp outside_root_allowlist_match?(
         %{pattern: pattern, reason_code: reason_code},
         normalized_path
       )
       when is_binary(pattern) and is_binary(reason_code) and reason_code != "" do
    path_pattern_match?(pattern, normalized_path)
  end

  defp outside_root_allowlist_match?(_entry, _normalized_path), do: false

  defp authorize_with_reason(state, tool_name, args, tool_safety) do
    if tool_allowed?(state, tool_name) do
      case network_allowed_with_reason(state, args, tool_safety) do
        :ok -> validate_arg_paths(state, args)
        {:error, _reason} = error -> error
      end
    else
      {:error, :denied}
    end
  end

  defp network_allowed_with_reason(state, args, tool_safety) do
    if network_access_required?(tool_safety),
      do: network_allowed_for_capable_tool(state, args),
      else: :ok
  end

  defp network_allowed_for_capable_tool(%{network_egress_policy: :allow} = state, args) do
    case validate_network_schemes(state.network_allowed_schemes, args) do
      :ok -> validate_network_allowlist(state.network_allowlist, args)
      {:error, _reason} = error -> error
    end
  end

  defp network_allowed_for_capable_tool(_state, _args), do: {:error, :network_denied}

  defp validate_network_allowlist([], _args), do: :ok

  defp validate_network_allowlist(allowlist, args) do
    args
    |> extract_network_targets()
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if allowed_network_target?(allowlist, target) do
        {:cont, :ok}
      else
        {:halt, {:error, :network_endpoint_denied}}
      end
    end)
  end

  defp validate_network_schemes(allowed_schemes, args) do
    args
    |> extract_network_schemes()
    |> Enum.reduce_while(:ok, fn scheme, :ok ->
      if scheme in allowed_schemes do
        {:cont, :ok}
      else
        {:halt, {:error, :network_protocol_denied}}
      end
    end)
  end

  defp extract_network_schemes(args) do
    args
    |> extract_network_values()
    |> Enum.map(&extract_network_scheme/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_network_targets(args) do
    args
    |> extract_network_values()
    |> Enum.map(&normalize_network_target/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_network_values(args) do
    collect_network_values(args, [])
    |> Enum.reverse()
  end

  defp collect_network_values(%_{} = _struct, acc), do: acc

  defp collect_network_values(args, acc) when is_map(args) do
    Enum.reduce(args, acc, fn {key, value}, inner_acc ->
      if network_target_key?(normalize_network_key(key)) do
        collect_network_values_for_target_value(value, inner_acc)
      else
        collect_network_values(value, inner_acc)
      end
    end)
  end

  defp collect_network_values(args, acc) when is_list(args) do
    Enum.reduce(args, acc, &collect_network_values(&1, &2))
  end

  defp collect_network_values(args, acc) when is_tuple(args) do
    args
    |> Tuple.to_list()
    |> collect_network_values(acc)
  end

  defp collect_network_values(args, acc) when is_binary(args) do
    trimmed = String.trim(args)

    if trimmed == "" do
      acc
    else
      case decode_network_payload(trimmed) do
        {:ok, decoded} -> collect_network_values(decoded, acc)
        :error -> collect_opaque_network_blob_values(acc, trimmed)
      end
    end
  end

  defp collect_network_values(_args, acc), do: acc

  defp collect_network_values_for_target_value(value, acc) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      maybe_collect_decoded_network_payload(value, trimmed, acc)
    end
  end

  defp collect_network_values_for_target_value(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_network_values_for_target_value(&1, &2))
  end

  defp collect_network_values_for_target_value(value, acc) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_network_values_for_target_value(acc)
  end

  defp collect_network_values_for_target_value(%_{} = _struct, acc), do: acc

  defp collect_network_values_for_target_value(value, acc) when is_map(value) do
    collect_network_values(value, acc)
  end

  defp collect_network_values_for_target_value(_value, acc), do: acc

  defp maybe_collect_decoded_network_payload(original_value, trimmed_value, acc) do
    case decode_network_payload(trimmed_value) do
      {:ok, decoded} ->
        collect_network_values_for_target_value(decoded, acc)

      :error ->
        acc
        |> prepend_network_value(original_value)
        |> collect_opaque_network_blob_values(trimmed_value)
    end
  end

  defp prepend_network_value(acc, value) when is_binary(value), do: [value | acc]

  defp collect_opaque_network_blob_values(acc, value) when is_binary(value) do
    value
    |> extract_opaque_network_blob_values()
    |> Enum.reduce(acc, fn candidate, inner_acc ->
      [candidate | inner_acc]
    end)
  end

  defp extract_opaque_network_blob_values(value) when is_binary(value) do
    url_values =
      @opaque_url_pattern
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.map(&match_capture/1)
      |> Enum.reject(&is_nil/1)

    keyed_values =
      @opaque_keyed_value_pattern
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.map(&keyed_value_capture/1)
      |> Enum.reject(&is_nil/1)

    (url_values ++ keyed_values)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp match_capture([candidate]) when is_binary(candidate), do: candidate
  defp match_capture(_match), do: nil

  defp keyed_value_capture([_key, value]) when is_binary(value), do: value
  defp keyed_value_capture(_match), do: nil

  defp decode_network_payload(value) when is_binary(value) do
    if network_payload_json?(value) do
      case Jason.decode(value) do
        {:ok, decoded} -> {:ok, decoded}
        _ -> :error
      end
    else
      :error
    end
  end

  defp network_payload_json?(value) when is_binary(value) do
    String.starts_with?(value, "{") or
      String.starts_with?(value, "[") or
      String.starts_with?(value, "\"")
  end

  defp normalize_network_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_network_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_network_key(_key), do: ""

  defp extract_network_scheme(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.contains?(trimmed, "://") do
      normalize_network_scheme(URI.parse(trimmed).scheme)
    else
      nil
    end
  end

  defp extract_network_scheme(_value), do: nil

  defp network_target_key?(key) do
    String.contains?(key, "url") or
      String.contains?(key, "uri") or
      String.contains?(key, "host") or
      String.contains?(key, "domain") or
      String.contains?(key, "endpoint")
  end

  defp normalize_network_target(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      uri = URI.parse(trimmed)

      if is_binary(uri.host) and uri.host != "" do
        String.downcase(uri.host)
      else
        normalize_network_host_candidate(trimmed)
      end
    end
  end

  defp normalize_network_host_candidate(value) when is_binary(value) do
    candidate =
      value
      |> String.trim_leading("//")
      |> String.split(["/", "?", "#"], parts: 2)
      |> List.first("")
      |> String.split("@")
      |> List.last()
      |> drop_port_suffix()
      |> String.trim()

    if candidate == "", do: nil, else: String.downcase(candidate)
  end

  defp drop_port_suffix(host) when is_binary(host) do
    cond do
      host == "" ->
        ""

      String.starts_with?(host, "[") ->
        host
        |> String.trim_leading("[")
        |> String.split("]", parts: 2)
        |> List.first("")

      true ->
        host
        |> String.split(":", parts: 2)
        |> List.first("")
    end
  end

  defp allowed_network_target?(allowlist, target) do
    Enum.any?(allowlist, fn entry ->
      target == entry or String.ends_with?(target, "." <> entry)
    end)
  end

  defp tool_visible_under_network_policy?(state, tool_spec) do
    if network_access_required?(extract_tool_safety(tool_spec)) do
      state.network_egress_policy == :allow
    else
      true
    end
  end

  defp extract_tool_safety(tool_spec) when is_map(tool_spec) do
    Map.get(tool_spec, :safety) || Map.get(tool_spec, "safety") || %{}
  end

  defp network_access_required?(safety) when is_map(safety) do
    Map.get(safety, :network_capable) == true or
      Map.get(safety, "network_capable") == true
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

  defp normalize_network_policy(:allow), do: :allow
  defp normalize_network_policy("allow"), do: :allow
  defp normalize_network_policy(_), do: :deny

  defp normalize_network_allowlist(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&normalize_network_target/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_network_allowlist(_), do: []

  defp normalize_network_schemes(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_network_scheme/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_network_schemes(_), do: Config.network_allowed_schemes()

  defp normalize_network_scheme(scheme) when is_binary(scheme) do
    normalized = scheme |> String.trim() |> String.downcase()
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_network_scheme(_scheme), do: nil

  defp normalize_path_patterns(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_path_patterns(_), do: []

  defp normalize_outside_root_allowlist(list, root_path)
       when is_list(list) and is_binary(root_path) do
    root = root_path |> Path.expand() |> resolve_symlinks()

    list
    |> Enum.map(&normalize_outside_root_allowlist_entry(&1, root))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn %{pattern: pattern, reason_code: reason_code} ->
      {pattern, reason_code}
    end)
  end

  defp normalize_outside_root_allowlist(list, _root_path) when is_list(list) do
    list
    |> Enum.map(&normalize_outside_root_allowlist_entry(&1, nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn %{pattern: pattern, reason_code: reason_code} ->
      {pattern, reason_code}
    end)
  end

  defp normalize_outside_root_allowlist(_list, _root_path), do: []

  defp normalize_outside_root_allowlist_entry(entry, root) when is_map(entry) do
    pattern =
      Map.get(entry, :pattern) ||
        Map.get(entry, "pattern") ||
        Map.get(entry, :path) ||
        Map.get(entry, "path")

    reason_code = Map.get(entry, :reason_code) || Map.get(entry, "reason_code")

    with {:ok, normalized_pattern} <- normalize_outside_root_pattern(pattern, root),
         {:ok, normalized_reason_code} <- normalize_reason_code(reason_code) do
      %{pattern: normalized_pattern, reason_code: normalized_reason_code}
    else
      :error -> nil
    end
  end

  defp normalize_outside_root_allowlist_entry(_entry, _root), do: nil

  defp normalize_outside_root_pattern(pattern, root) when is_binary(pattern) do
    trimmed = String.trim(pattern)

    if trimmed == "" do
      :error
    else
      expanded =
        case root do
          root when is_binary(root) -> expand_user_path(trimmed, root)
          _ -> Path.expand(trimmed)
        end

      normalized_pattern = expanded |> resolve_symlinks() |> String.replace("\\", "/")
      {:ok, normalized_pattern}
    end
  end

  defp normalize_outside_root_pattern(_pattern, _root), do: :error

  defp normalize_reason_code(reason_code) when is_binary(reason_code) do
    trimmed = String.trim(reason_code)
    if trimmed == "", do: :error, else: {:ok, trimmed}
  end

  defp normalize_reason_code(_reason_code), do: :error

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

  defp validate_sensitive_path(state, resolved_path) do
    root = state.root_path |> Path.expand() |> String.replace("\\", "/")
    relative = Path.relative_to(resolved_path, root) |> String.replace("\\", "/")

    if sensitive_path_denied?(
         relative,
         state.sensitive_path_denylist,
         state.sensitive_path_allowlist
       ) do
      {:error, :sensitive_path_denied}
    else
      :ok
    end
  end

  defp sensitive_path_denied?(relative, denylist, allowlist) do
    denied = Enum.any?(denylist, &path_pattern_match?(&1, relative))
    allowed = Enum.any?(allowlist, &path_pattern_match?(&1, relative))
    denied and not allowed
  end

  defp path_pattern_match?(pattern, relative) do
    normalized_pattern = String.replace(pattern, "\\", "/")
    basename = Path.basename(relative)

    if String.contains?(normalized_pattern, "/") do
      wildcard_match?(relative, normalized_pattern)
    else
      wildcard_match?(basename, normalized_pattern)
    end
  rescue
    _error -> false
  end

  defp wildcard_match?(value, pattern) when is_binary(value) and is_binary(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex}$/, value)
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

  defp resolve_path(root_path, user_path) do
    root = root_path |> Path.expand() |> resolve_symlinks()
    candidate = expand_user_path(user_path, root)
    resolved = resolve_symlinks(candidate)

    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, root, resolved}
      _ -> {:error, :invalid_root_path}
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
    end

    maybe_emit_security_signal(decision)
  end

  defp maybe_emit_security_signal(%{outside_root_exception_reason_codes: reason_codes} = decision)
       when is_list(reason_codes) and reason_codes != [] do
    Enum.each(reason_codes, fn reason_code ->
      Telemetry.emit(
        "security.sandbox_exception_used",
        Map.put(decision, :reason_code, reason_code)
      )
    end)
  end

  defp maybe_emit_security_signal(%{reason: :outside_root} = decision) do
    Telemetry.emit("security.sandbox_violation", decision)
  end

  defp maybe_emit_security_signal(%{reason: :network_denied} = decision) do
    Telemetry.emit("security.network_denied", decision)
  end

  defp maybe_emit_security_signal(%{reason: :network_endpoint_denied} = decision) do
    Telemetry.emit("security.network_denied", decision)
  end

  defp maybe_emit_security_signal(%{reason: :network_protocol_denied} = decision) do
    Telemetry.emit("security.network_denied", decision)
  end

  defp maybe_emit_security_signal(%{reason: :sensitive_path_denied} = decision) do
    Telemetry.emit("security.sensitive_path_denied", decision)
  end

  defp maybe_emit_security_signal(_decision), do: :ok

  defp default_authorization_meta do
    %{outside_root_exception_reason_codes: []}
  end

  defp put_outside_root_reason_code(authorization_meta, reason_code)
       when is_binary(reason_code) and reason_code != "" do
    reason_codes =
      authorization_meta
      |> Map.get(:outside_root_exception_reason_codes, [])
      |> Kernel.++([reason_code])
      |> Enum.uniq()

    Map.put(authorization_meta, :outside_root_exception_reason_codes, reason_codes)
  end

  defp put_outside_root_reason_code(authorization_meta, _reason_code), do: authorization_meta

  defp extract_conversation_id(meta, ctx) do
    Map.get(meta, :conversation_id) ||
      Map.get(meta, "conversation_id") ||
      Map.get(ctx, :conversation_id) ||
      Map.get(ctx, "conversation_id")
  end

  defp extract_correlation_id(meta, ctx) do
    case Correlation.fetch(meta) do
      {:ok, correlation_id} ->
        correlation_id

      :error ->
        case Correlation.fetch(ctx) do
          {:ok, correlation_id} -> correlation_id
          :error -> nil
        end
    end
  end
end
