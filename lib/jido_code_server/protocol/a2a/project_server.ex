defmodule Jido.Code.Server.Protocol.A2A.ProjectServer do
  @moduledoc """
  Per-project A2A adapter that delegates to the global A2A gateway logic.
  """

  use GenServer

  alias Jido.Code.Server.Protocol.A2A.Gateway

  @type task_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec agent_card(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def agent_card(server) do
    GenServer.call(server, :agent_card)
  end

  @spec task_create(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def task_create(server, content, opts \\ [])
      when is_binary(content) and is_list(opts) do
    GenServer.call(server, {:task_create, content, opts})
  end

  @spec message_send(GenServer.server(), task_id(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def message_send(server, task_id, content, opts \\ [])
      when is_binary(task_id) and is_binary(content) and is_list(opts) do
    GenServer.call(server, {:message_send, task_id, content, opts})
  end

  @spec task_cancel(GenServer.server(), task_id(), keyword()) :: :ok | {:error, term()}
  def task_cancel(server, task_id, opts \\ [])
      when is_binary(task_id) and is_list(opts) do
    GenServer.call(server, {:task_cancel, task_id, opts})
  end

  @spec subscribe_task(GenServer.server(), task_id(), pid()) :: :ok | {:error, term()}
  def subscribe_task(server, task_id, pid \\ self())
      when is_binary(task_id) and is_pid(pid) do
    GenServer.call(server, {:subscribe_task, task_id, pid})
  end

  @spec unsubscribe_task(GenServer.server(), task_id(), pid()) :: :ok | {:error, term()}
  def unsubscribe_task(server, task_id, pid \\ self())
      when is_binary(task_id) and is_pid(pid) do
    GenServer.call(server, {:unsubscribe_task, task_id, pid})
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    {:ok, %{project_id: project_id, opts: opts}}
  end

  @impl true
  def handle_call(:agent_card, _from, state) do
    {:reply, Gateway.agent_card(state.project_id), state}
  end

  def handle_call({:task_create, content, opts}, _from, state) do
    {:reply, Gateway.task_create(state.project_id, content, opts), state}
  end

  def handle_call({:message_send, task_id, content, opts}, _from, state) do
    {:reply, Gateway.message_send(state.project_id, task_id, content, opts), state}
  end

  def handle_call({:task_cancel, task_id, opts}, _from, state) do
    {:reply, Gateway.task_cancel(state.project_id, task_id, opts), state}
  end

  def handle_call({:subscribe_task, task_id, pid}, _from, state) do
    {:reply, Gateway.subscribe_task(state.project_id, task_id, pid), state}
  end

  def handle_call({:unsubscribe_task, task_id, pid}, _from, state) do
    {:reply, Gateway.unsubscribe_task(state.project_id, task_id, pid), state}
  end
end
