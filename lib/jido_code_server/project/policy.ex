defmodule JidoCodeServer.Project.Policy do
  @moduledoc """
  Sandbox policy placeholder.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end

  @spec normalize_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, :outside_root}
  def normalize_path(root_path, user_path) do
    resolved = Path.expand(user_path, root_path)

    if String.starts_with?(resolved, Path.expand(root_path)) do
      {:ok, resolved}
    else
      {:error, :outside_root}
    end
  end

  @spec authorize_tool(String.t(), map(), map()) :: :ok | {:error, :denied | :not_implemented}
  def authorize_tool(_tool_name, _args, _ctx), do: {:error, :not_implemented}

  @spec filter_tools(list(map())) :: list(map())
  def filter_tools(tool_specs), do: tool_specs
end
