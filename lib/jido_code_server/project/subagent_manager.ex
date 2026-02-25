defmodule Jido.Code.Server.Project.SubAgentManager do
  @moduledoc """
  Tracks policy-gated sub-agent lifecycle per project.
  """

  use GenServer

  alias Jido.Code.Server.Project.SubAgentRef
  alias Jido.Code.Server.Project.SubAgentTemplate
  alias Jido.Code.Server.Telemetry

  @type template :: SubAgentTemplate.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec spawn_from_template(GenServer.server(), template(), String.t(), map(), map()) ::
          {:ok, SubAgentRef.t()} | {:error, term()}
  def spawn_from_template(
        server,
        %SubAgentTemplate{} = template,
        owner_conversation_id,
        request,
        ctx
      )
      when is_binary(owner_conversation_id) and is_map(request) and is_map(ctx) do
    GenServer.call(server, {:spawn, template, owner_conversation_id, request, ctx})
  end

  @spec stop_children_for_conversation(GenServer.server(), String.t(), term(), keyword()) :: :ok
  def stop_children_for_conversation(
        server,
        owner_conversation_id,
        reason \\ :conversation_cancelled,
        opts \\ []
      )
      when is_binary(owner_conversation_id) and is_list(opts) do
    notify = Keyword.get(opts, :notify, true)

    GenServer.call(
      server,
      {:stop_children_for_conversation, owner_conversation_id, reason, notify}
    )
  end

  @spec list_children(GenServer.server(), String.t() | nil) :: [SubAgentRef.t()]
  def list_children(server, owner_conversation_id \\ nil) do
    GenServer.call(server, {:list_children, owner_conversation_id})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       project_id: Keyword.get(opts, :project_id),
       notify: Keyword.get(opts, :notify),
       default_max_children: Keyword.get(opts, :default_max_children, 3),
       default_ttl_ms: Keyword.get(opts, :default_ttl_ms, 300_000),
       children: %{}
     }}
  end

  @impl true
  def handle_call({:spawn, template, owner_conversation_id, request, ctx}, _from, state) do
    reply =
      with :ok <- validate_spawn_request(request),
           :ok <- enforce_quota(state, template, owner_conversation_id),
           {:ok, child} <- start_child(template, owner_conversation_id, request, ctx) do
        Telemetry.emit("conversation.subagent.started", %{
          project_id: state.project_id,
          conversation_id: owner_conversation_id,
          child_id: child.ref.child_id,
          template_id: child.ref.template_id,
          correlation_id: child.ref.correlation_id
        })

        {:ok, child.ref, put_child(state, child)}
      end

    case reply do
      {:ok, ref, next_state} ->
        {:reply, {:ok, ref}, next_state}

      {:error, reason} ->
        maybe_emit_spawn_denied(state, owner_conversation_id, template, reason, ctx)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:stop_children_for_conversation, owner_conversation_id, reason, notify?},
        _from,
        state
      ) do
    {to_stop, keep} = split_children_by_owner(state.children, owner_conversation_id)

    Enum.each(to_stop, fn {_child_id, child} ->
      terminate_child(child, reason)

      if notify? do
        notify(
          state.notify,
          {:subagent_stopped, owner_conversation_id, subagent_ref_to_map(child.ref)}
        )
      end
    end)

    {:reply, :ok, %{state | children: keep}}
  end

  def handle_call({:list_children, owner_conversation_id}, _from, state) do
    children =
      state.children
      |> Map.values()
      |> Enum.map(& &1.ref)
      |> maybe_filter_owner(owner_conversation_id)
      |> Enum.sort_by(& &1.child_id)

    {:reply, children, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case pop_child_by_monitor_ref(state.children, monitor_ref) do
      {nil, children} ->
        {:noreply, %{state | children: children}}

      {child, children} ->
        terminal_status = terminal_status(reason)
        ref = %{child.ref | status: terminal_status}

        signal_type =
          case terminal_status do
            :completed -> :subagent_completed
            :failed -> :subagent_failed
            :stopped -> :subagent_stopped
          end

        notify(
          state.notify,
          {signal_type, ref.owner_conversation_id, subagent_ref_to_map(ref), reason}
        )

        Telemetry.emit("conversation.subagent.#{terminal_status}", %{
          project_id: state.project_id,
          conversation_id: ref.owner_conversation_id,
          child_id: ref.child_id,
          template_id: ref.template_id,
          correlation_id: ref.correlation_id,
          reason: reason
        })

        if is_reference(child.ttl_timer_ref) do
          Process.cancel_timer(child.ttl_timer_ref)
        end

        {:noreply, %{state | children: children}}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:ttl_expired, child_id}, state) do
    case Map.get(state.children, child_id) do
      nil ->
        {:noreply, state}

      child ->
        if is_pid(child.ref.pid) and Process.alive?(child.ref.pid) do
          Process.exit(child.ref.pid, :kill)
        end

        Telemetry.emit("security.subagent.quota_denied", %{
          project_id: state.project_id,
          conversation_id: child.ref.owner_conversation_id,
          child_id: child_id,
          correlation_id: child.ref.correlation_id,
          reason: :ttl_expired
        })

        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(state.children, fn {_child_id, child} ->
      terminate_child(child, reason || :shutdown)
    end)

    :ok
  end

  defp validate_spawn_request(request) when is_map(request) do
    goal = Map.get(request, "goal") || Map.get(request, :goal)

    if is_binary(goal) and String.trim(goal) != "" do
      :ok
    else
      {:error, :invalid_spawn_request}
    end
  end

  defp enforce_quota(state, template, owner_conversation_id) do
    max_children = template.max_children_per_conversation || state.default_max_children

    active_count =
      state.children
      |> Map.values()
      |> Enum.count(fn child ->
        child.ref.owner_conversation_id == owner_conversation_id and
          child.ref.status in [:starting, :running]
      end)

    if active_count < max_children do
      :ok
    else
      {:error, :subagent_quota_exceeded}
    end
  end

  defp start_child(template, owner_conversation_id, request, ctx) do
    child_id = "subagent_" <> Integer.to_string(System.unique_integer([:positive]))
    correlation_id = Map.get(ctx, :correlation_id) || Map.get(ctx, "correlation_id")

    ttl_ms =
      request
      |> Map.get("ttl_ms", Map.get(request, :ttl_ms))
      |> normalize_positive_integer(template.ttl_ms)

    with {:ok, pid} <- do_start_child(template, child_id, request, ctx) do
      monitor_ref = Process.monitor(pid)
      ttl_timer_ref = Process.send_after(self(), {:ttl_expired, child_id}, ttl_ms)

      ref = %SubAgentRef{
        child_id: child_id,
        template_id: template.template_id,
        owner_conversation_id: owner_conversation_id,
        pid: pid,
        started_at: DateTime.utc_now(),
        status: :running,
        correlation_id: correlation_id
      }

      child = %{ref: ref, monitor_ref: monitor_ref, ttl_timer_ref: ttl_timer_ref}
      {:ok, child}
    end
  end

  defp do_start_child(
         %SubAgentTemplate{agent_module: module, initial_state: initial_state},
         child_id,
         _request,
         _ctx
       )
       when is_atom(module) do
    if function_exported?(module, :new, 0) or function_exported?(module, :new, 1) do
      Jido.AgentServer.start_link(
        agent: module,
        id: child_id,
        initial_state: initial_state,
        register_global: false
      )
    else
      {:error, :invalid_agent_module}
    end
  rescue
    error ->
      {:error, {:subagent_start_failed, error}}
  end

  defp do_start_child(_template, _child_id, _request, _ctx), do: {:error, :invalid_template}

  defp put_child(state, child) do
    %{state | children: Map.put(state.children, child.ref.child_id, child)}
  end

  defp split_children_by_owner(children, owner_conversation_id) do
    {to_stop, keep} =
      children
      |> Map.to_list()
      |> Enum.split_with(fn {_child_id, child} ->
        child.ref.owner_conversation_id == owner_conversation_id
      end)

    {to_stop, Map.new(keep)}
  end

  defp pop_child_by_monitor_ref(children, monitor_ref) do
    Enum.reduce(children, {nil, children}, fn {child_id, child}, {found, acc} ->
      cond do
        found ->
          {found, acc}

        child.monitor_ref == monitor_ref ->
          {child, Map.delete(acc, child_id)}

        true ->
          {nil, acc}
      end
    end)
  end

  defp maybe_filter_owner(children, nil), do: children

  defp maybe_filter_owner(children, owner_conversation_id) do
    Enum.filter(children, fn ref -> ref.owner_conversation_id == owner_conversation_id end)
  end

  defp terminate_child(child, reason) do
    if is_reference(child.ttl_timer_ref), do: Process.cancel_timer(child.ttl_timer_ref)
    if is_reference(child.monitor_ref), do: Process.demonitor(child.monitor_ref, [:flush])

    if is_pid(child.ref.pid) and Process.alive?(child.ref.pid) do
      Process.exit(child.ref.pid, reason)
    end

    :ok
  end

  defp terminal_status(:normal), do: :completed
  defp terminal_status(:shutdown), do: :stopped
  defp terminal_status({:shutdown, _reason}), do: :stopped
  defp terminal_status(:killed), do: :stopped
  defp terminal_status(_reason), do: :failed

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp notify(pid, message) when is_pid(pid), do: send(pid, message)
  defp notify(_pid, _message), do: :ok

  defp maybe_emit_spawn_denied(state, owner_conversation_id, template, reason, ctx) do
    event =
      case reason do
        :subagent_quota_exceeded -> "security.subagent.quota_denied"
        :denied -> "security.subagent.spawn_denied"
        _ -> "security.subagent.policy_violation"
      end

    Telemetry.emit(event, %{
      project_id: state.project_id,
      conversation_id: owner_conversation_id,
      template_id: template.template_id,
      correlation_id: Map.get(ctx, :correlation_id) || Map.get(ctx, "correlation_id"),
      reason: reason
    })
  end

  defp subagent_ref_to_map(ref) do
    %{
      "child_id" => ref.child_id,
      "template_id" => ref.template_id,
      "owner_conversation_id" => ref.owner_conversation_id,
      "pid" => inspect(ref.pid),
      "started_at" => DateTime.to_iso8601(ref.started_at),
      "status" => Atom.to_string(ref.status),
      "correlation_id" => ref.correlation_id
    }
  end
end
