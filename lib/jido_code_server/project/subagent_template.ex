defmodule Jido.Code.Server.Project.SubAgentTemplate do
  @moduledoc """
  Policy-gated sub-agent template definition.
  """

  @type t :: %__MODULE__{
          template_id: String.t(),
          agent_module: module(),
          initial_state: map(),
          allowed_tools: [String.t()],
          network_policy: :allow | :deny,
          env_allowlist: [String.t()],
          ttl_ms: pos_integer(),
          max_children_per_conversation: pos_integer(),
          spawn_timeout_ms: pos_integer()
        }

  @enforce_keys [:template_id, :agent_module]
  defstruct template_id: nil,
            agent_module: nil,
            initial_state: %{},
            allowed_tools: [],
            network_policy: :deny,
            env_allowlist: [],
            ttl_ms: 300_000,
            max_children_per_conversation: 3,
            spawn_timeout_ms: 30_000

  @spec from_map(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_map(raw, opts \\ [])

  def from_map(raw, opts) when is_map(raw) do
    default_ttl_ms = Keyword.get(opts, :default_ttl_ms, 300_000)
    default_max_children = Keyword.get(opts, :default_max_children, 3)

    with template_id when is_binary(template_id) and template_id != "" <-
           map_get(raw, "template_id"),
         agent_module when is_atom(agent_module) <- map_get(raw, "agent_module") do
      {:ok,
       %__MODULE__{
         template_id: template_id,
         agent_module: agent_module,
         initial_state: normalize_map(map_get(raw, "initial_state") || %{}),
         allowed_tools: normalize_string_list(map_get(raw, "allowed_tools") || []),
         network_policy: normalize_network_policy(map_get(raw, "network_policy")),
         env_allowlist: normalize_string_list(map_get(raw, "env_allowlist") || []),
         ttl_ms: normalize_positive_integer(map_get(raw, "ttl_ms"), default_ttl_ms),
         max_children_per_conversation:
           normalize_positive_integer(
             map_get(raw, "max_children_per_conversation"),
             default_max_children
           ),
         spawn_timeout_ms: normalize_positive_integer(map_get(raw, "spawn_timeout_ms"), 30_000)
       }}
    else
      _ -> {:error, :invalid_template}
    end
  end

  def from_map(_raw, _opts), do: {:error, :invalid_template}

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_value), do: []

  defp normalize_network_policy(:allow), do: :allow
  defp normalize_network_policy("allow"), do: :allow
  defp normalize_network_policy(_policy), do: :deny

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
