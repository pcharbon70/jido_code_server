defmodule Jido.Code.Server.Project.Loaders.SkillGraph do
  @moduledoc """
  Loads a skill graph snapshot from markdown files in `.jido/skill_graph`.
  """

  @spec load(map()) :: {:ok, %{snapshot: map(), errors: list(map())}} | {:error, term()}
  def load(layout) when is_map(layout) do
    directory = Map.fetch!(layout, :skill_graph)
    files = directory |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort()

    {nodes_by_name, edges, errors} =
      Enum.reduce(files, {%{}, [], []}, fn path, {acc_nodes, acc_edges, acc_errors} ->
        relative_path = Path.relative_to(path, directory)
        node_id = path |> Path.rootname() |> Path.basename()

        case Map.has_key?(acc_nodes, node_id) do
          true ->
            error = load_error(path, {:duplicate_node, node_id})
            {acc_nodes, acc_edges, [error | acc_errors]}

          false ->
            read_graph_file(acc_nodes, acc_edges, acc_errors, path, relative_path, node_id)
        end
      end)

    nodes =
      nodes_by_name
      |> Map.values()
      |> Enum.sort_by(& &1.id)

    edge_set =
      edges
      |> Enum.uniq_by(&{&1.from, &1.to})
      |> Enum.sort_by(&{&1.from, &1.to})

    snapshot = %{
      nodes: nodes,
      edges: edge_set
    }

    {:ok, %{snapshot: snapshot, errors: Enum.reverse(errors)}}
  end

  defp extract_title(body, fallback) do
    case Regex.run(~r/^#\s+(.+)$/m, body, capture: :all_but_first) do
      [title] -> String.trim(title)
      _ -> fallback
    end
  end

  defp extract_links(body) do
    Regex.scan(~r/\[\[([^\]]+)\]\]/, body, capture: :all_but_first)
    |> Enum.map(fn [target] -> String.trim(target) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp read_graph_file(acc_nodes, acc_edges, acc_errors, path, relative_path, node_id) do
    case File.read(path) do
      {:ok, body} ->
        case normalize_body(body) do
          {:ok, normalized_body} ->
            node = %{
              id: node_id,
              path: path,
              relative_path: relative_path,
              title: extract_title(normalized_body, node_id)
            }

            links = extract_links(normalized_body)
            edges_for_node = Enum.map(links, &%{from: node_id, to: &1})

            {Map.put(acc_nodes, node_id, node), edges_for_node ++ acc_edges, acc_errors}

          :error ->
            {acc_nodes, acc_edges, [load_error(path, :invalid_utf8) | acc_errors]}
        end

      {:error, reason} ->
        {acc_nodes, acc_edges, [load_error(path, reason) | acc_errors]}
    end
  end

  defp normalize_body(body) when is_binary(body) do
    if String.valid?(body), do: {:ok, body}, else: :error
  end

  defp load_error(path, reason) do
    %{
      type: :skill_graph,
      loader: __MODULE__,
      path: path,
      reason: reason
    }
  end
end
