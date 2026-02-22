defmodule JidoCodeServer.Project.Layout do
  @moduledoc """
  Filesystem layout helpers for project runtime directories.
  """

  @required_dirs ["skills", "commands", "workflows", "skill_graph", "state"]

  @spec paths(String.t(), String.t()) :: map()
  def paths(root_path, data_dir) do
    data = Path.join(root_path, data_dir)

    %{
      root: root_path,
      data: data,
      skills: Path.join(data, "skills"),
      commands: Path.join(data, "commands"),
      workflows: Path.join(data, "workflows"),
      skill_graph: Path.join(data, "skill_graph"),
      state: Path.join(data, "state")
    }
  end

  @spec canonical_root(String.t()) :: {:ok, String.t()} | {:error, {:invalid_root_path, term()}}
  def canonical_root(root_path) when is_binary(root_path) do
    expanded = Path.expand(root_path)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, expanded}

      {:ok, _other} ->
        {:error, {:invalid_root_path, :not_directory}}

      {:error, reason} ->
        {:error, {:invalid_root_path, reason}}
    end
  end

  def canonical_root(_root_path), do: {:error, {:invalid_root_path, :expected_string}}

  @spec ensure_layout(String.t(), String.t()) ::
          {:ok, map()} | {:error, {:layout_create_failed, term()}}
  def ensure_layout(root_path, data_dir) do
    layout = paths(root_path, data_dir)

    case mkdir(layout.data) do
      :ok ->
        case ensure_required_dirs(layout.data) do
          :ok -> {:ok, layout}
          {:error, reason} -> {:error, {:layout_create_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:layout_create_failed, reason}}
    end
  end

  @spec ensure_layout!(String.t(), String.t()) :: map()
  def ensure_layout!(root_path, data_dir) do
    case ensure_layout(root_path, data_dir) do
      {:ok, layout} ->
        layout

      {:error, reason} ->
        raise ArgumentError, "failed to create project layout: #{inspect(reason)}"
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp ensure_required_dirs(data_root) do
    Enum.reduce_while(@required_dirs, :ok, fn dir, :ok ->
      data_root
      |> Path.join(dir)
      |> mkdir()
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
