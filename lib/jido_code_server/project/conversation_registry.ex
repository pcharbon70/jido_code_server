defmodule Jido.Code.Server.Project.ConversationRegistry do
  @moduledoc """
  Project-local in-memory conversation registry.
  """

  use GenServer

  @type conversation_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec put(GenServer.server(), conversation_id(), pid()) :: :ok
  def put(server, conversation_id, pid) when is_binary(conversation_id) and is_pid(pid) do
    GenServer.call(server, {:put, conversation_id, pid})
  end

  @spec fetch(GenServer.server(), conversation_id()) :: {:ok, pid()} | :error
  def fetch(server, conversation_id) when is_binary(conversation_id) do
    GenServer.call(server, {:fetch, conversation_id})
  end

  @spec delete(GenServer.server(), conversation_id()) :: :ok
  def delete(server, conversation_id) when is_binary(conversation_id) do
    GenServer.call(server, {:delete, conversation_id})
  end

  @spec delete_by_pid(GenServer.server(), pid()) :: :ok
  def delete_by_pid(server, pid) when is_pid(pid) do
    GenServer.call(server, {:delete_by_pid, pid})
  end

  @spec list(GenServer.server()) :: [{conversation_id(), pid()}]
  def list(server) do
    GenServer.call(server, :list)
  end

  @impl true
  def init(_opts) do
    {:ok, %{by_id: %{}, by_pid: %{}}}
  end

  @impl true
  def handle_call({:put, conversation_id, pid}, _from, state) do
    new_state = %{
      by_id: Map.put(state.by_id, conversation_id, pid),
      by_pid: Map.put(state.by_pid, pid, conversation_id)
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:fetch, conversation_id}, _from, state) do
    reply =
      case Map.fetch(state.by_id, conversation_id) do
        {:ok, pid} when is_pid(pid) -> {:ok, pid}
        _ -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, conversation_id}, _from, state) do
    {pid, by_id} = Map.pop(state.by_id, conversation_id)

    by_pid =
      case pid do
        nil -> state.by_pid
        _ -> Map.delete(state.by_pid, pid)
      end

    {:reply, :ok, %{by_id: by_id, by_pid: by_pid}}
  end

  def handle_call({:delete_by_pid, pid}, _from, state) do
    case Map.pop(state.by_pid, pid) do
      {nil, by_pid} ->
        {:reply, :ok, %{state | by_pid: by_pid}}

      {conversation_id, by_pid} ->
        by_id = Map.delete(state.by_id, conversation_id)
        {:reply, :ok, %{by_id: by_id, by_pid: by_pid}}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.to_list(state.by_id), state}
  end
end
