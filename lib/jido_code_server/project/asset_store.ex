defmodule Jido.Code.Server.Project.AssetStore do
  @moduledoc """
  ETS-backed asset store shared by all conversations in a project.
  """

  use GenServer

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Project.Loaders.Command
  alias Jido.Code.Server.Project.Loaders.Skill
  alias Jido.Code.Server.Project.Loaders.SkillGraph
  alias Jido.Code.Server.Project.Loaders.Workflow
  alias Jido.Code.Server.Telemetry

  @asset_types [:skill, :command, :workflow, :skill_graph]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec load(GenServer.server(), map(), keyword()) :: :ok | {:error, term()}
  def load(server, layout, opts \\ []) when is_map(layout) do
    GenServer.call(server, {:load, layout, opts})
  end

  @spec reload(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def reload(server, opts \\ []) do
    GenServer.call(server, {:reload, opts})
  end

  @spec get(GenServer.server(), atom() | String.t(), atom() | String.t()) ::
          {:ok, term()} | :error
  def get(server, type, key) do
    GenServer.call(server, {:get, type, key})
  end

  @spec list(GenServer.server(), atom() | String.t()) :: [map()]
  def list(server, type) do
    GenServer.call(server, {:list, type})
  end

  @spec search(GenServer.server(), atom() | String.t(), String.t()) :: [map()]
  def search(server, type, query) when is_binary(query) do
    GenServer.call(server, {:search, type, query})
  end

  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(server) do
    GenServer.call(server, :diagnostics)
  end

  @impl true
  def init(opts) do
    strict = Keyword.get(opts, :strict, Config.strict_asset_loading())

    state = %{
      opts: opts,
      project_id: Keyword.get(opts, :project_id),
      strict: strict,
      loaders: default_loaders() |> Map.merge(Map.new(Keyword.get(opts, :loaders, []))),
      table: new_table(),
      layout: nil,
      generation: 0,
      versions: zero_versions(),
      last_counts: zero_counts(),
      last_errors: [],
      last_loaded_at: nil
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    delete_table(state.table)
    :ok
  end

  @impl true
  def handle_call({:load, layout, opts}, _from, state) do
    strict = Keyword.get(opts, :strict, state.strict)
    do_load(state, layout, :load, strict)
  end

  def handle_call({:reload, opts}, _from, state) do
    strict = Keyword.get(opts, :strict, state.strict)

    case state.layout do
      nil ->
        {:reply, {:error, :layout_not_loaded}, state}

      layout ->
        do_load(state, layout, :reload, strict)
    end
  end

  def handle_call({:get, type, key}, _from, state) do
    reply =
      with {:ok, normalized_type} <- normalize_type(type),
           {:ok, lookup_key} <- normalize_lookup_key(normalized_type, key),
           [value] <-
             :ets.lookup(state.table, lookup_key) |> Enum.map(fn {_key, value} -> value end) do
        {:ok, value}
      else
        _ -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:list, type}, _from, state) do
    reply =
      case normalize_type(type) do
        {:ok, :skill_graph} ->
          case :ets.lookup(state.table, {:skill_graph, :snapshot}) do
            [{{:skill_graph, :snapshot}, snapshot}] -> [snapshot]
            _ -> []
          end

        {:ok, normalized_type} ->
          normalized_type
          |> list_from_table(state.table)
          |> Enum.sort_by(& &1.name)

        {:error, _reason} ->
          []
      end

    {:reply, reply, state}
  end

  def handle_call({:search, type, query}, _from, state) do
    normalized_query = String.trim(query) |> String.downcase()

    reply =
      case {normalize_type(type), normalized_query} do
        {{:ok, _normalized_type}, ""} ->
          []

        {{:ok, :skill_graph}, query_text} ->
          search_skill_graph(state.table, query_text)

        {{:ok, normalized_type}, query_text} ->
          search_assets(state.table, normalized_type, query_text)

        _ ->
          []
      end

    {:reply, reply, state}
  end

  def handle_call(:diagnostics, _from, state) do
    {:reply, diagnostics_from_state(state), state}
  end

  defp do_load(state, layout, mode, strict) do
    case load_snapshot(layout, state.loaders) do
      {:ok, snapshot, errors} ->
        maybe_apply_snapshot(state, layout, mode, strict, snapshot, errors)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_apply_snapshot(state, _layout, _mode, true, _snapshot, errors) when errors != [] do
    {:reply, {:error, {:asset_load_failed, errors}}, state}
  end

  defp maybe_apply_snapshot(state, layout, mode, strict, snapshot, errors) do
    case build_table(snapshot) do
      {:ok, next_table} ->
        delete_table(state.table)

        generation = state.generation + 1
        versions = version_map(generation)
        counts = snapshot_counts(snapshot)
        loaded_at = DateTime.utc_now()

        emit_load_event(mode, state.project_id, generation, versions, counts, errors)

        next_state = %{
          state
          | table: next_table,
            layout: layout,
            strict: strict,
            generation: generation,
            versions: versions,
            last_counts: counts,
            last_errors: errors,
            last_loaded_at: loaded_at
        }

        {:reply, :ok, next_state}

      {:error, reason} ->
        {:reply, {:error, {:asset_store_swap_failed, reason}}, state}
    end
  end

  defp load_snapshot(layout, loaders) do
    with {:ok, skill_result} <- run_loader(loaders.skill, layout),
         {:ok, command_result} <- run_loader(loaders.command, layout),
         {:ok, workflow_result} <- run_loader(loaders.workflow, layout),
         {:ok, graph_result} <- run_loader(loaders.skill_graph, layout) do
      snapshot = %{
        skills: Map.get(skill_result, :assets, []),
        commands: Map.get(command_result, :assets, []),
        workflows: Map.get(workflow_result, :assets, []),
        skill_graph: Map.get(graph_result, :snapshot, %{nodes: [], edges: []})
      }

      errors =
        skill_result
        |> Map.get(:errors, [])
        |> Kernel.++(Map.get(command_result, :errors, []))
        |> Kernel.++(Map.get(workflow_result, :errors, []))
        |> Kernel.++(Map.get(graph_result, :errors, []))

      {:ok, snapshot, errors}
    end
  end

  defp run_loader(loader, layout) when is_atom(loader) do
    case loader.load(layout) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:ok, _unexpected} ->
        {:error, {:invalid_loader_result, loader}}

      {:error, reason} ->
        {:error, {:loader_failed, loader, reason}}
    end
  end

  defp build_table(snapshot) do
    table = new_table()

    entries = [
      Enum.map(snapshot.skills, fn asset -> {{:skill, asset.name}, asset} end),
      Enum.map(snapshot.commands, fn asset -> {{:command, asset.name}, asset} end),
      Enum.map(snapshot.workflows, fn asset -> {{:workflow, asset.name}, asset} end),
      [{{:skill_graph, :snapshot}, snapshot.skill_graph}]
    ]

    try do
      entries
      |> List.flatten()
      |> then(&:ets.insert(table, &1))

      {:ok, table}
    rescue
      error ->
        delete_table(table)
        {:error, error}
    end
  end

  defp emit_load_event(mode, project_id, generation, versions, counts, errors) do
    event_name =
      case mode do
        :load -> "project.assets_loaded"
        :reload -> "project.assets_reloaded"
      end

    Telemetry.emit(event_name, %{
      project_id: project_id,
      generation: generation,
      versions: versions,
      counts: counts,
      error_count: length(errors)
    })
  end

  defp search_assets(table, type, query) do
    list_from_table(type, table)
    |> Enum.filter(fn asset ->
      matches_query?(asset.name, query) or
        matches_query?(Map.get(asset, :body, ""), query) or
        matches_query?(Map.get(asset, :relative_path, ""), query)
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp search_skill_graph(table, query) do
    case :ets.lookup(table, {:skill_graph, :snapshot}) do
      [{{:skill_graph, :snapshot}, snapshot}] ->
        nodes =
          snapshot.nodes
          |> Enum.filter(fn node ->
            matches_query?(node.id, query) or matches_query?(Map.get(node, :title, ""), query)
          end)
          |> Enum.sort_by(& &1.id)

        edges =
          snapshot.edges
          |> Enum.filter(fn edge ->
            matches_query?(edge.from, query) or matches_query?(edge.to, query)
          end)
          |> Enum.sort_by(&{&1.from, &1.to})

        if nodes == [] and edges == [] do
          []
        else
          [%{nodes: nodes, edges: edges}]
        end

      _ ->
        []
    end
  end

  defp list_from_table(type, table) do
    :ets.match_object(table, {{type, :_}, :_})
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp matches_query?(value, query) when is_binary(value) and is_binary(query) do
    value
    |> String.downcase()
    |> String.contains?(query)
  end

  defp matches_query?(_value, _query), do: false

  defp normalize_lookup_key(:skill_graph, key) do
    case key do
      :snapshot -> {:ok, {:skill_graph, :snapshot}}
      "snapshot" -> {:ok, {:skill_graph, :snapshot}}
      _ -> {:error, {:invalid_asset_key, key}}
    end
  end

  defp normalize_lookup_key(type, key) when is_atom(type) do
    case key do
      value when is_binary(value) and value != "" ->
        {:ok, {type, value}}

      value when is_atom(value) ->
        {:ok, {type, Atom.to_string(value)}}

      _ ->
        {:error, {:invalid_asset_key, key}}
    end
  end

  defp normalize_type(type) when type in @asset_types, do: {:ok, type}

  defp normalize_type(type) when is_binary(type) do
    case String.downcase(type) do
      "skill" -> {:ok, :skill}
      "command" -> {:ok, :command}
      "workflow" -> {:ok, :workflow}
      "skill_graph" -> {:ok, :skill_graph}
      _ -> {:error, {:invalid_asset_type, type}}
    end
  end

  defp normalize_type(type), do: {:error, {:invalid_asset_type, type}}

  defp diagnostics_from_state(state) do
    %{
      project_id: state.project_id,
      loaded?: not is_nil(state.layout),
      strict: state.strict,
      generation: state.generation,
      versions: state.versions,
      counts: state.last_counts,
      errors: state.last_errors,
      last_loaded_at: state.last_loaded_at
    }
  end

  defp default_loaders do
    %{
      skill: Skill,
      command: Command,
      workflow: Workflow,
      skill_graph: SkillGraph
    }
  end

  defp version_map(generation) do
    %{
      skill: generation,
      command: generation,
      workflow: generation,
      skill_graph: generation
    }
  end

  defp zero_versions do
    %{
      skill: 0,
      command: 0,
      workflow: 0,
      skill_graph: 0
    }
  end

  defp snapshot_counts(snapshot) do
    %{
      skill: length(snapshot.skills),
      command: length(snapshot.commands),
      workflow: length(snapshot.workflows),
      skill_graph_nodes: length(snapshot.skill_graph.nodes),
      skill_graph_edges: length(snapshot.skill_graph.edges)
    }
  end

  defp zero_counts do
    %{
      skill: 0,
      command: 0,
      workflow: 0,
      skill_graph_nodes: 0,
      skill_graph_edges: 0
    }
  end

  defp new_table do
    :ets.new(__MODULE__, [:set, :private, read_concurrency: true])
  end

  defp delete_table(table) do
    case :ets.info(table) do
      :undefined ->
        :ok

      _info ->
        :ets.delete(table)
        :ok
    end
  end
end
