defmodule JidoCodeServer.Conversation.Server do
  @moduledoc """
  Thin GenServer wrapper shell around a conversation runtime instance.

  Phase 2 keeps this process intentionally minimal:
  - accepts inbound events
  - stores event timeline
  - exposes projection reads for timeline and llm context
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec get_projection(GenServer.server(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(server, key) do
    GenServer.call(server, {:get_projection, key})
  end

  @spec ingest_event(GenServer.server(), map()) :: :ok
  def ingest_event(server, event) when is_map(event) do
    GenServer.call(server, {:event, event})
  end

  @impl true
  def init(opts) do
    state = %{
      opts: opts,
      project_id: Keyword.get(opts, :project_id),
      conversation_id: Keyword.get(opts, :conversation_id),
      events: [],
      subscribers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_projection, :timeline}, _from, state) do
    {:reply, {:ok, Enum.reverse(state.events)}, state}
  end

  def handle_call({:event, event}, _from, state) do
    {:reply, :ok, %{state | events: [event | state.events]}}
  end

  def handle_call({:get_projection, :llm_context}, _from, state) do
    projection = %{
      project_id: state.project_id,
      conversation_id: state.conversation_id,
      events: Enum.reverse(state.events)
    }

    {:reply, {:ok, projection}, state}
  end

  def handle_call({:get_projection, _key}, _from, state) do
    {:reply, {:error, :projection_not_found}, state}
  end
end
