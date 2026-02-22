defmodule Jido.Code.Server.Protocol.A2A.Gateway do
  @moduledoc """
  Global A2A adapter that maps task/message operations to conversation events.
  """

  use GenServer

  alias Jido.Code.Server.Engine

  @type project_id :: String.t()
  @type task_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec agent_card(project_id(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def agent_card(project_id, server \\ __MODULE__) when is_binary(project_id) do
    GenServer.call(server, {:agent_card, project_id})
  end

  @spec task_create(project_id(), String.t(), keyword(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def task_create(project_id, content, opts \\ [], server \\ __MODULE__)
      when is_binary(project_id) and is_binary(content) and is_list(opts) do
    GenServer.call(server, {:task_create, project_id, content, opts})
  end

  @spec message_send(project_id(), task_id(), String.t(), keyword(), GenServer.server()) ::
          :ok | {:error, term()}
  def message_send(project_id, task_id, content, opts \\ [], server \\ __MODULE__)
      when is_binary(project_id) and is_binary(task_id) and is_binary(content) and is_list(opts) do
    GenServer.call(server, {:message_send, project_id, task_id, content, opts})
  end

  @spec task_cancel(project_id(), task_id(), keyword(), GenServer.server()) ::
          :ok | {:error, term()}
  def task_cancel(project_id, task_id, opts \\ [], server \\ __MODULE__)
      when is_binary(project_id) and is_binary(task_id) and is_list(opts) do
    GenServer.call(server, {:task_cancel, project_id, task_id, opts})
  end

  @spec subscribe_task(project_id(), task_id(), pid(), GenServer.server()) ::
          :ok | {:error, term()}
  def subscribe_task(project_id, task_id, pid \\ self(), server \\ __MODULE__)
      when is_binary(project_id) and is_binary(task_id) and is_pid(pid) do
    GenServer.call(server, {:subscribe_task, project_id, task_id, pid})
  end

  @spec unsubscribe_task(project_id(), task_id(), pid(), GenServer.server()) ::
          :ok | {:error, term()}
  def unsubscribe_task(project_id, task_id, pid \\ self(), server \\ __MODULE__)
      when is_binary(project_id) and is_binary(task_id) and is_pid(pid) do
    GenServer.call(server, {:unsubscribe_task, project_id, task_id, pid})
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end

  @impl true
  def handle_call({:agent_card, project_id}, _from, state) do
    reply =
      with :ok <- ensure_project(project_id) do
        tools = Engine.list_tools(project_id)
        skills = Engine.list_assets(project_id, :skill)
        commands = Engine.list_assets(project_id, :command)
        workflows = Engine.list_assets(project_id, :workflow)

        {:ok,
         %{
           project_id: project_id,
           agent_id: "jidocodeserver:#{project_id}",
           protocols: ["a2a"],
           capabilities: %{
             tool_count: length(tools),
             tools: Enum.map(tools, &Map.take(&1, [:name, :description, :input_schema])),
             asset_counts: %{
               skills: length(skills),
               commands: length(commands),
               workflows: length(workflows)
             }
           }
         }}
      end

    {:reply, reply, state}
  end

  def handle_call({:task_create, project_id, content, opts}, _from, state) do
    reply =
      with :ok <- ensure_project(project_id),
           :ok <- validate_content(content),
           {:ok, conversation_id} <- Engine.start_conversation(project_id, start_opts(opts)),
           :ok <-
             Engine.send_event(
               project_id,
               conversation_id,
               user_message_event(content, opts, "a2a.task.create")
             ) do
        {:ok,
         %{
           task_id: conversation_id,
           conversation_id: conversation_id,
           status: "running",
           project_id: project_id
         }}
      end

    {:reply, reply, state}
  end

  def handle_call({:message_send, project_id, task_id, content, opts}, _from, state) do
    reply =
      with :ok <- ensure_project(project_id),
           :ok <- validate_content(content) do
        Engine.send_event(
          project_id,
          task_id,
          user_message_event(content, opts, "a2a.message.send")
        )
      end

    {:reply, reply, state}
  end

  def handle_call({:task_cancel, project_id, task_id, opts}, _from, state) do
    reason = Keyword.get(opts, :reason, :cancelled)

    reply =
      with :ok <- ensure_project(project_id) do
        Engine.send_event(project_id, task_id, %{
          "type" => "conversation.cancel",
          "meta" => %{
            "protocol" => "a2a",
            "source" => "a2a.task.cancel",
            "reason" => normalize_reason(reason)
          }
        })
      end

    {:reply, reply, state}
  end

  def handle_call({:subscribe_task, project_id, task_id, pid}, _from, state) do
    reply =
      with :ok <- ensure_project(project_id) do
        Engine.subscribe_conversation(project_id, task_id, pid)
      end

    {:reply, reply, state}
  end

  def handle_call({:unsubscribe_task, project_id, task_id, pid}, _from, state) do
    reply =
      with :ok <- ensure_project(project_id) do
        Engine.unsubscribe_conversation(project_id, task_id, pid)
      end

    {:reply, reply, state}
  end

  defp ensure_project(project_id) do
    case Engine.whereis_project(project_id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_content(content) do
    if String.trim(content) == "" do
      {:error, :empty_content}
    else
      :ok
    end
  end

  defp start_opts(opts) do
    case Keyword.get(opts, :task_id) do
      id when is_binary(id) and id != "" -> [conversation_id: id]
      _ -> []
    end
  end

  defp user_message_event(content, opts, source) do
    meta =
      opts
      |> Keyword.get(:meta, %{})
      |> Map.new()
      |> Map.put_new("protocol", "a2a")
      |> Map.put_new("source", source)

    %{
      "type" => "user.message",
      "content" => content,
      "meta" => meta
    }
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)
end
