defmodule Jido.Code.Server.Conversation.ModeConfig do
  @moduledoc """
  Resolves effective conversation mode configuration with deterministic precedence.
  """

  alias Jido.Code.Server.Conversation.ModeRegistry

  @type mode_source :: :request | :conversation | :project | :default

  @spec resolve(keyword() | map(), map() | nil, map()) ::
          {:ok, map()} | {:error, map()}
  def resolve(request_opts, conversation_state, project_ctx)
      when (is_list(request_opts) or is_map(request_opts)) and is_map(project_ctx) do
    normalized_request = normalize_request_opts(request_opts)
    conversation_state = normalize_map(conversation_state)

    {mode, mode_source} =
      resolve_mode(
        map_get(normalized_request, "mode"),
        map_get(conversation_state, "mode"),
        project_default_mode(project_ctx)
      )

    case ModeRegistry.fetch(mode, project_ctx) do
      {:ok, mode_spec} ->
        merged_mode_state =
          mode_spec
          |> Map.get(:defaults, %{})
          |> deep_merge(mode_defaults_from_project(project_ctx, mode))
          |> deep_merge(normalize_map(map_get(conversation_state, "mode_state")))
          |> deep_merge(map_get(normalized_request, "mode_state") |> normalize_map())

        unknown_key_policy = unknown_key_policy(project_ctx)

        case validate_mode_state(mode_spec, merged_mode_state, unknown_key_policy) do
          :ok ->
            {:ok,
             %{
               mode: mode,
               mode_state: merged_mode_state,
               mode_spec: mode_spec,
               unknown_key_policy: unknown_key_policy,
               diagnostics: %{
                 mode_source: mode_source,
                 option_layers: [
                   "mode_defaults",
                   "project_defaults",
                   "conversation_state",
                   "request"
                 ]
               }
             }}

          {:error, errors} ->
            {:error,
             %{
               code: :invalid_mode_config,
               mode: mode,
               mode_source: mode_source,
               unknown_key_policy: unknown_key_policy,
               errors: errors
             }}
        end

      {:error, :unknown_mode} ->
        {:error,
         %{
           code: :invalid_mode_config,
           mode: mode,
           mode_source: mode_source,
           unknown_key_policy: unknown_key_policy(project_ctx),
           errors: [%{path: "mode", reason: :unknown_mode, message: "unknown conversation mode"}]
         }}
    end
  end

  def resolve(_request_opts, _conversation_state, _project_ctx),
    do: {:error, %{code: :invalid_mode_config, errors: [%{path: "mode", reason: :invalid_input}]}}

  defp normalize_request_opts(opts) when is_list(opts) do
    mode_state =
      Keyword.get(opts, :mode_state) ||
        Keyword.get(opts, :mode_options) ||
        %{}

    %{
      "mode" => Keyword.get(opts, :mode),
      "mode_state" => normalize_map(mode_state)
    }
  end

  defp normalize_request_opts(opts) when is_map(opts) do
    %{
      "mode" => map_get(opts, "mode"),
      "mode_state" =>
        map_get(opts, "mode_state") ||
          map_get(opts, "mode_options") ||
          %{}
    }
  end

  defp resolve_mode(request_mode, conversation_mode, project_mode) do
    cond do
      not is_nil(request_mode) ->
        {normalize_mode(request_mode), :request}

      not is_nil(conversation_mode) ->
        {normalize_mode(conversation_mode), :conversation}

      not is_nil(project_mode) ->
        {normalize_mode(project_mode), :project}

      true ->
        {ModeRegistry.default_mode(), :default}
    end
  end

  defp project_default_mode(project_ctx) do
    map_get(project_ctx, "conversation_default_mode") || map_get(project_ctx, "default_mode")
  end

  defp mode_defaults_from_project(project_ctx, mode) do
    defaults =
      map_get(project_ctx, "conversation_mode_defaults") ||
        map_get(project_ctx, "mode_defaults") ||
        %{}

    mode_key = Atom.to_string(mode)

    cond do
      is_map(defaults[mode]) ->
        defaults[mode]

      is_map(defaults[mode_key]) ->
        defaults[mode_key]

      is_map(defaults[:all]) ->
        defaults[:all]

      is_map(defaults["all"]) ->
        defaults["all"]

      true ->
        %{}
    end
  end

  defp unknown_key_policy(project_ctx) do
    case map_get(project_ctx, "conversation_mode_unknown_key_policy") ||
           map_get(project_ctx, "mode_unknown_key_policy") do
      :allow -> :allow
      "allow" -> :allow
      _ -> :reject
    end
  end

  defp validate_mode_state(mode_spec, mode_state, unknown_key_policy) do
    option_schema =
      mode_spec
      |> Map.get(:option_schema, %{})
      |> normalize_option_schema()

    required_options =
      mode_spec
      |> Map.get(:required_options, [])
      |> Enum.map(&normalize_key/1)
      |> Enum.reject(&is_nil/1)

    allowed_keys = Map.keys(option_schema)
    normalized_state = normalize_string_key_map(mode_state)

    missing_required_errors =
      required_options
      |> Enum.reject(&Map.has_key?(normalized_state, &1))
      |> Enum.map(fn key ->
        %{path: "mode_state.#{key}", reason: :missing_required_option}
      end)

    unknown_key_errors =
      normalized_state
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))
      |> case do
        [] ->
          []

        _keys when unknown_key_policy == :allow ->
          []

        keys ->
          Enum.map(keys, fn key ->
            %{path: "mode_state.#{key}", reason: :unknown_option}
          end)
      end

    type_errors =
      Enum.reduce(option_schema, [], fn {key, expected_type}, acc ->
        case Map.fetch(normalized_state, key) do
          :error ->
            acc

          {:ok, value} ->
            add_type_error(acc, key, expected_type, value)
        end
      end)
      |> Enum.reverse()

    errors = missing_required_errors ++ unknown_key_errors ++ type_errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp normalize_option_schema(schema) when is_map(schema) do
    Enum.reduce(schema, %{}, fn {key, value}, acc ->
      normalized_key = normalize_key(key)
      normalized_type = normalize_option_type(value)

      if is_binary(normalized_key), do: Map.put(acc, normalized_key, normalized_type), else: acc
    end)
  end

  defp normalize_option_schema(_schema), do: %{}

  defp normalize_option_type(value)
       when value in [:atom, :boolean, :integer, :list, :map, :string],
       do: value

  defp normalize_option_type(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "atom" -> :atom
      "boolean" -> :boolean
      "integer" -> :integer
      "list" -> :list
      "map" -> :map
      "string" -> :string
      _ -> :string
    end
  end

  defp normalize_option_type(_value), do: :string

  defp matches_type?(value, :atom), do: is_atom(value)
  defp matches_type?(value, :boolean), do: is_boolean(value)
  defp matches_type?(value, :integer), do: is_integer(value)
  defp matches_type?(value, :list), do: is_list(value)
  defp matches_type?(value, :map), do: is_map(value)
  defp matches_type?(value, :string), do: is_binary(value)
  defp matches_type?(_value, _type), do: true

  defp add_type_error(acc, key, expected_type, value) do
    if matches_type?(value, expected_type) do
      acc
    else
      [%{path: "mode_state.#{key}", reason: {:invalid_type, expected_type}} | acc]
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp deep_merge(_left, right), do: right

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> ModeRegistry.default_mode()
      value -> String.to_atom(value)
    end
  end

  defp normalize_mode(_mode), do: ModeRegistry.default_mode()

  defp normalize_string_key_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = normalize_key(key)

      normalized_value =
        cond do
          is_map(nested) -> normalize_string_key_map(nested)
          is_list(nested) -> Enum.map(nested, &normalize_string_key_map/1)
          true -> nested
        end

      if is_binary(normalized_key), do: Map.put(acc, normalized_key, normalized_value), else: acc
    end)
  end

  defp normalize_string_key_map(value) when is_list(value),
    do: Enum.map(value, &normalize_string_key_map/1)

  defp normalize_string_key_map(value), do: value

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
