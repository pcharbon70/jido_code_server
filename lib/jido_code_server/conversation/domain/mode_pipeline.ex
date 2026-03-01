defmodule Jido.Code.Server.Conversation.Domain.ModePipeline do
  @moduledoc """
  Canonical baseline mode pipeline templates used by step planning.
  """

  @type template :: %{
          mode: atom(),
          template_id: String.t(),
          template_version: String.t(),
          start_step: String.t(),
          step_chain: [String.t()],
          continue_on: [String.t()],
          terminal_signals: %{optional(String.t()) => [String.t()]},
          extension_points: [String.t()],
          output_profile: String.t()
        }

  @builtin_templates %{
    coding: %{
      mode: :coding,
      template_id: "coding.baseline",
      template_version: "1.0.0",
      start_step: "strategy.start",
      step_chain: ["strategy:code_generation", "tool:*", "strategy:code_generation"],
      continue_on: ["conversation.tool.completed", "conversation.tool.failed"],
      terminal_signals: %{
        "completed" => ["conversation.llm.completed"],
        "failed" => ["conversation.llm.failed"]
      },
      extension_points: ["strategy.override", "tool.exposure_policy", "completion.guardrails"],
      output_profile: "code_changes"
    },
    planning: %{
      mode: :planning,
      template_id: "planning.artifact.baseline",
      template_version: "1.0.0",
      start_step: "strategy.start",
      step_chain: ["strategy:planning", "tool:read_only", "strategy:planning"],
      continue_on: ["conversation.tool.completed", "conversation.tool.failed"],
      terminal_signals: %{
        "completed" => ["conversation.llm.completed"],
        "failed" => ["conversation.llm.failed"]
      },
      extension_points: ["artifact.schema", "artifact.sections", "plan.depth"],
      output_profile: "structured_artifact"
    },
    engineering: %{
      mode: :engineering,
      template_id: "engineering.tradeoff.baseline",
      template_version: "1.0.0",
      start_step: "strategy.start",
      step_chain: ["strategy:engineering_design", "tool:*", "strategy:engineering_design"],
      continue_on: ["conversation.tool.completed", "conversation.tool.failed"],
      terminal_signals: %{
        "completed" => ["conversation.llm.completed"],
        "failed" => ["conversation.llm.failed"]
      },
      extension_points: ["analysis.constraints", "analysis.alternatives", "analysis.tradeoffs"],
      output_profile: "tradeoff_analysis"
    }
  }

  @spec resolve(atom() | String.t() | nil, map()) :: template()
  def resolve(mode, mode_state \\ %{}) when is_map(mode_state) do
    base =
      mode
      |> normalize_mode()
      |> then(&Map.get(@builtin_templates, &1, @builtin_templates.coding))

    pipeline_state = map_get(mode_state, "pipeline") |> normalize_map()

    %{
      base
      | template_id:
          normalize_string(map_get(mode_state, "pipeline_template_id")) ||
            normalize_string(map_get(pipeline_state, "template_id")) ||
            base.template_id,
        template_version:
          normalize_string(map_get(mode_state, "pipeline_template_version")) ||
            normalize_string(map_get(pipeline_state, "template_version")) ||
            base.template_version,
        extension_points:
          normalize_string_list(
            map_get(mode_state, "pipeline_extension_points") ||
              map_get(pipeline_state, "extension_points")
          ) || base.extension_points,
        output_profile:
          normalize_string(map_get(mode_state, "pipeline_output_profile")) ||
            normalize_string(map_get(pipeline_state, "output_profile")) ||
            base.output_profile
    }
  end

  @spec continue_signal?(template(), String.t()) :: boolean()
  def continue_signal?(template, signal_type) when is_map(template) and is_binary(signal_type) do
    signal_type in Map.get(template, :continue_on, [])
  end

  @spec terminal_status_for_signal(template(), String.t()) :: :completed | :failed | nil
  def terminal_status_for_signal(template, signal_type)
      when is_map(template) and is_binary(signal_type) do
    terminal_signals = Map.get(template, :terminal_signals, %{})

    cond do
      signal_type in Map.get(terminal_signals, "completed", []) -> :completed
      signal_type in Map.get(terminal_signals, "failed", []) -> :failed
      true -> nil
    end
  end

  @spec pipeline_meta(template(), keyword()) :: map()
  def pipeline_meta(template, opts \\ []) when is_map(template) and is_list(opts) do
    %{
      "reason" => Keyword.get(opts, :reason),
      "run_id" => Keyword.get(opts, :run_id),
      "step_index" => Keyword.get(opts, :step_index),
      "predecessor_step_id" => Keyword.get(opts, :predecessor_step_id),
      "retry_count" => Keyword.get(opts, :retry_count),
      "max_retries" => Keyword.get(opts, :max_retries),
      "retry_attempt" => Keyword.get(opts, :retry_attempt),
      "retry_backoff_ms" => Keyword.get(opts, :retry_backoff_ms),
      "retry_policy" => Keyword.get(opts, :retry_policy),
      "template_id" => Map.get(template, :template_id),
      "template_version" => Map.get(template, :template_version),
      "mode" => template_mode_label(template),
      "start_step" => Map.get(template, :start_step),
      "step_chain" => Map.get(template, :step_chain, []),
      "continue_on" => Map.get(template, :continue_on, []),
      "terminal_signals" => Map.get(template, :terminal_signals, %{}),
      "extension_points" => Map.get(template, :extension_points, []),
      "output_profile" => Map.get(template, :output_profile)
    }
  end

  defp template_mode_label(template) do
    case Map.get(template, :mode) do
      mode when is_atom(mode) -> Atom.to_string(mode)
      mode when is_binary(mode) -> mode
      _other -> "coding"
    end
  end

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case String.trim(mode) |> String.downcase() do
      "coding" -> :coding
      "planning" -> :planning
      "engineering" -> :engineering
      _other -> :coding
    end
  end

  defp normalize_mode(_mode), do: :coding

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    normalized =
      values
      |> Enum.map(&normalize_string/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if normalized == [], do: nil, else: normalized
  end

  defp normalize_string_list(_values), do: nil

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
