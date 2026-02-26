defmodule Jido.Code.Server.Conversation.Agent do
  @moduledoc """
  Agent-first conversation runtime on top of `Jido.AgentServer`.
  """

  @dialyzer {:nowarn_function, plugin_specs: 0}

  use Jido.Agent,
    name: "jido_code_server_conversation_agent",
    description: "Signal-first conversation runtime",
    schema: [
      project_id: [type: :string, required: true],
      conversation_id: [type: :string, required: true],
      domain: [type: :map, required: true],
      project_ctx: [type: :map, required: true]
    ],
    signal_routes: [
      {"conversation.cmd.ingest", Jido.Code.Server.Conversation.Actions.IngestSignalAction},
      {"conversation.cmd.drain", Jido.Code.Server.Conversation.Actions.DrainQueueAction},
      {"conversation.cmd.cancel", Jido.Code.Server.Conversation.Actions.CancelConversationAction}
    ]

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @type snapshot :: %{
          project_id: String.t(),
          conversation_id: String.t(),
          status: atom(),
          queue_size: non_neg_integer(),
          pending_tool_calls: [map()],
          pending_subagents: [map()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    project_ctx =
      opts
      |> Keyword.get(:project_ctx, %{})
      |> Map.new()
      |> Map.put(:project_id, project_id)
      |> Map.put(:conversation_id, conversation_id)

    domain =
      State.new(
        project_id: project_id,
        conversation_id: conversation_id,
        max_queue_size: Keyword.get(opts, :max_queue_size, Config.conversation_max_queue_size()),
        max_drain_steps:
          Keyword.get(opts, :max_drain_steps, Config.conversation_max_drain_steps()),
        orchestration_enabled: Keyword.get(opts, :orchestration_enabled, false)
      )

    initial_state = %{
      project_id: project_id,
      conversation_id: conversation_id,
      domain: domain,
      project_ctx: project_ctx
    }

    server_opts = [
      agent: __MODULE__,
      id: conversation_id,
      initial_state: initial_state,
      register_global: false,
      max_queue_size: Keyword.get(opts, :max_queue_size, Config.conversation_max_queue_size())
    ]

    Jido.AgentServer.start_link(server_opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :conversation_id, make_ref())},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec call(pid(), Jido.Signal.t(), timeout()) :: {:ok, snapshot()} | {:error, term()}
  def call(server, %Jido.Signal{} = signal, timeout \\ 30_000) do
    with {:ok, normalized_signal} <- ConversationSignal.normalize(signal),
         :ok <- validate_external_signal_type(normalized_signal.type),
         {:ok, _agent} <-
           Jido.AgentServer.call(server, ingest_command_signal(normalized_signal), timeout),
         {:ok, state} <- state(server) do
      {:ok, snapshot(state)}
    end
  end

  @spec cast(pid(), Jido.Signal.t()) :: :ok | {:error, term()}
  def cast(server, %Jido.Signal{} = signal) do
    with {:ok, normalized_signal} <- ConversationSignal.normalize(signal),
         :ok <- validate_external_signal_type(normalized_signal.type) do
      Jido.AgentServer.cast(server, ingest_command_signal(normalized_signal))
    end
  end

  @spec cancel(pid(), String.t()) :: {:ok, snapshot()} | {:error, term()}
  def cancel(server, reason \\ "cancelled") do
    signal =
      Jido.Signal.new!("conversation.cmd.cancel", %{"reason" => reason},
        source: "/conversation/runtime"
      )

    with {:ok, _agent} <- Jido.AgentServer.call(server, signal, 30_000),
         {:ok, state} <- state(server) do
      {:ok, snapshot(state)}
    end
  end

  @spec state(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def state(server, _timeout \\ 30_000) do
    with {:ok, runtime_state} <- Jido.AgentServer.state(server) do
      {:ok, runtime_state.agent.state}
    end
  end

  @spec projection(pid(), atom() | String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def projection(server, key, timeout \\ 30_000) do
    with {:ok, state} <- state(server, timeout),
         domain when is_map(domain) <- state.domain,
         projection_key <- normalize_projection_key(key),
         {:ok, projection} <- fetch_projection(domain, projection_key) do
      {:ok, projection}
    else
      _ -> {:error, :projection_not_found}
    end
  end

  @spec enqueue_instruction_result(pid(), map()) :: :ok | {:error, term()}
  def enqueue_instruction_result(server, payload) when is_map(payload) do
    signal =
      Jido.Signal.new!("conversation.cmd.instruction.result", payload,
        source: "/conversation/runtime"
      )

    Jido.AgentServer.cast(server, signal)
  end

  defp ingest_command_signal(%Jido.Signal{} = signal) do
    Jido.Signal.new!("conversation.cmd.ingest", %{"signal" => ConversationSignal.to_map(signal)},
      source: "/conversation/runtime"
    )
  end

  defp snapshot(state) do
    domain = state.domain
    diagnostics = domain.projection_cache[:diagnostics] || %{}

    %{
      project_id: state.project_id,
      conversation_id: state.conversation_id,
      status: diagnostics[:status] || diagnostics["status"] || domain.status,
      queue_size: diagnostics[:queue_size] || diagnostics["queue_size"] || domain.queue_size,
      pending_tool_calls: domain.pending_tool_calls,
      pending_subagents: domain.pending_subagents |> Map.values()
    }
  end

  defp normalize_projection_key(key) when is_atom(key), do: key

  defp normalize_projection_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> case do
      "" ->
        :unknown_projection

      value ->
        try do
          String.to_existing_atom(value)
        rescue
          ArgumentError -> :unknown_projection
        end
    end
  end

  defp normalize_projection_key(_key), do: :unknown_projection

  defp fetch_projection(domain, key) do
    case Map.fetch(domain.projection_cache, key) do
      {:ok, projection} -> {:ok, projection}
      :error -> {:error, :projection_not_found}
    end
  end

  defp validate_external_signal_type("conversation.cmd." <> _suffix),
    do: {:error, {:reserved_type, "conversation.cmd.*"}}

  defp validate_external_signal_type(_type), do: :ok
end
