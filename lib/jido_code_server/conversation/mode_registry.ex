defmodule Jido.Code.Server.Conversation.ModeRegistry do
  @moduledoc """
  Canonical mode metadata and capability registry for conversation orchestration.
  """

  @type execution_kind ::
          :strategy_run
          | :tool_run
          | :command_run
          | :workflow_run
          | :subagent_spawn
          | atom()

  @type tool_policy :: %{
          optional(:allowed_execution_kinds) => :all | [execution_kind()]
        }

  @type mode_spec :: %{
          mode: atom(),
          title: String.t(),
          description: String.t(),
          defaults: map(),
          option_schema: %{
            optional(String.t()) => :atom | :boolean | :integer | :map | :list | :string
          },
          required_options: [String.t()],
          capabilities: %{
            optional(:strategy_support) => [atom()],
            optional(:tool_policy) => tool_policy(),
            optional(:interruption_semantics) => map()
          }
        }

  @default_mode :coding

  @builtin_modes %{
    coding: %{
      mode: :coding,
      title: "Coding",
      description: "Default code-first mode with full tool and strategy support.",
      defaults: %{
        "strategy" => "code_generation",
        "max_turn_steps" => 32
      },
      option_schema: %{
        "strategy" => :string,
        "max_turn_steps" => :integer
      },
      required_options: [],
      capabilities: %{
        strategy_support: [:code_generation, :reasoning, :tool_loop],
        tool_policy: %{allowed_execution_kinds: :all},
        interruption_semantics: %{
          supports_cancel: true,
          supports_resume: true
        }
      }
    },
    planning: %{
      mode: :planning,
      title: "Planning",
      description: "Plan-first mode optimized for analysis and low-risk read-only tooling.",
      defaults: %{
        "strategy" => "planning",
        "max_turn_steps" => 24
      },
      option_schema: %{
        "strategy" => :string,
        "max_turn_steps" => :integer
      },
      required_options: [],
      capabilities: %{
        strategy_support: [:planning, :reasoning],
        tool_policy: %{allowed_execution_kinds: [:tool_run]},
        interruption_semantics: %{
          supports_cancel: true,
          supports_resume: true
        }
      }
    },
    engineering: %{
      mode: :engineering,
      title: "Engineering",
      description: "Architecture and systems-design mode with broad strategy/tool support.",
      defaults: %{
        "strategy" => "engineering_design",
        "max_turn_steps" => 40
      },
      option_schema: %{
        "strategy" => :string,
        "max_turn_steps" => :integer
      },
      required_options: [],
      capabilities: %{
        strategy_support: [:engineering_design, :reasoning, :tool_loop],
        tool_policy: %{allowed_execution_kinds: :all},
        interruption_semantics: %{
          supports_cancel: true,
          supports_resume: true
        }
      }
    }
  }

  @spec default_mode() :: atom()
  def default_mode, do: @default_mode

  @spec builtins() :: %{optional(atom()) => mode_spec()}
  def builtins, do: @builtin_modes

  @spec list(map()) :: [mode_spec()]
  def list(project_ctx \\ %{}) when is_map(project_ctx) do
    project_ctx
    |> registry()
    |> Map.values()
    |> Enum.sort_by(&Atom.to_string(&1.mode))
  end

  @spec fetch(atom() | String.t() | nil, map()) :: {:ok, mode_spec()} | {:error, :unknown_mode}
  def fetch(mode, project_ctx \\ %{}) when is_map(project_ctx) do
    mode = normalize_mode(mode)

    case Map.fetch(registry(project_ctx), mode) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :unknown_mode}
    end
  end

  @spec capabilities(atom() | String.t() | nil, map()) :: {:ok, map()} | {:error, :unknown_mode}
  def capabilities(mode, project_ctx \\ %{}) when is_map(project_ctx) do
    with {:ok, spec} <- fetch(mode, project_ctx) do
      {:ok, Map.get(spec, :capabilities, %{})}
    end
  end

  @spec allowed_execution_kinds(atom() | String.t() | nil, map()) :: :all | [execution_kind()]
  def allowed_execution_kinds(mode, project_ctx \\ %{}) when is_map(project_ctx) do
    case capabilities(mode, project_ctx) do
      {:ok, capabilities} ->
        capabilities
        |> Map.get(:tool_policy, %{})
        |> Map.get(:allowed_execution_kinds, :all)
        |> normalize_allowed_execution_kinds()

      _ ->
        :all
    end
  end

  defp registry(project_ctx) do
    Map.merge(@builtin_modes, extension_registry(project_ctx))
  end

  defp extension_registry(project_ctx) do
    project_ctx
    |> mode_registry_extensions()
    |> Enum.reduce(%{}, fn candidate, acc ->
      case normalize_mode_spec(candidate) do
        {:ok, spec} -> Map.put(acc, spec.mode, spec)
        :error -> acc
      end
    end)
  end

  defp mode_registry_extensions(project_ctx) do
    case map_get(project_ctx, "mode_registry") ||
           map_get(project_ctx, "conversation_mode_registry") do
      nil ->
        []

      extensions when is_list(extensions) ->
        extensions

      %{} = extensions ->
        Map.values(extensions)

      _other ->
        []
    end
  end

  defp normalize_mode_spec(raw_spec) when is_map(raw_spec) do
    with mode when not is_nil(mode) <- map_get(raw_spec, "mode"),
         normalized_mode <- normalize_mode(mode),
         true <- is_atom(normalized_mode),
         defaults <- normalize_map(map_get(raw_spec, "defaults")),
         option_schema <- normalize_option_schema(map_get(raw_spec, "option_schema")),
         required_options <- normalize_required_options(map_get(raw_spec, "required_options")) do
      {:ok,
       %{
         mode: normalized_mode,
         title: normalize_string(map_get(raw_spec, "title"), humanize_mode(normalized_mode)),
         description: normalize_string(map_get(raw_spec, "description"), ""),
         defaults: defaults,
         option_schema: option_schema,
         required_options: required_options,
         capabilities: normalize_map(map_get(raw_spec, "capabilities"))
       }}
    else
      _ -> :error
    end
  end

  defp normalize_mode_spec(_raw_spec), do: :error

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> @default_mode
      value -> String.to_atom(value)
    end
  end

  defp normalize_mode(_mode), do: @default_mode

  defp normalize_option_schema(schema) when is_map(schema) do
    Enum.reduce(schema, %{}, fn {key, value}, acc ->
      normalized_key = normalize_key(key)
      normalized_type = normalize_option_type(value)

      if is_binary(normalized_key) and is_atom(normalized_type) do
        Map.put(acc, normalized_key, normalized_type)
      else
        acc
      end
    end)
  end

  defp normalize_option_schema(_schema), do: %{}

  defp normalize_option_type(type) when type in [:atom, :boolean, :integer, :map, :list, :string],
    do: type

  defp normalize_option_type(type) when is_binary(type) do
    case String.downcase(String.trim(type)) do
      "atom" -> :atom
      "boolean" -> :boolean
      "integer" -> :integer
      "map" -> :map
      "list" -> :list
      "string" -> :string
      _ -> :string
    end
  end

  defp normalize_option_type(_type), do: :string

  defp normalize_required_options(values) when is_list(values) do
    values
    |> Enum.map(&normalize_key/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_required_options(_values), do: []

  defp normalize_allowed_execution_kinds(:all), do: :all

  defp normalize_allowed_execution_kinds(values) when is_list(values) do
    values
    |> Enum.map(&normalize_execution_kind/1)
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_execution_kinds(_values), do: :all

  defp normalize_execution_kind(kind) when is_atom(kind), do: kind

  defp normalize_execution_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> String.to_atom(value)
    end
  end

  defp normalize_execution_kind(_kind), do: nil

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_value), do: %{}

  defp normalize_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp normalize_string(_value, fallback), do: fallback

  defp humanize_mode(mode) when is_atom(mode) do
    mode
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

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
