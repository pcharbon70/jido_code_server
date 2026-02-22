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

  @spec ensure_layout!(String.t(), String.t()) :: map()
  def ensure_layout!(root_path, data_dir) do
    layout = paths(root_path, data_dir)

    File.mkdir_p!(layout.data)

    Enum.each(@required_dirs, fn dir ->
      File.mkdir_p!(Path.join(layout.data, dir))
    end)

    layout
  end
end
