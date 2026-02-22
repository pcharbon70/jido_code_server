defmodule Jido.Code.Server.Project.Loaders.Common do
  @moduledoc false

  @type asset_type :: :skill | :command | :workflow
  @type asset :: %{
          type: asset_type(),
          name: String.t(),
          path: String.t(),
          relative_path: String.t(),
          body: String.t()
        }

  @type load_error :: %{
          type: asset_type(),
          loader: module(),
          path: String.t(),
          reason: term()
        }

  @spec load_markdown_assets(map(), atom(), module()) :: %{
          assets: [asset()],
          errors: [load_error()]
        }
  def load_markdown_assets(layout, type, loader_module) when is_map(layout) and is_atom(type) do
    directory = Map.fetch!(layout, type_to_dir_key(type))
    files = directory |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort()

    {assets_by_name, errors} =
      Enum.reduce(files, {%{}, []}, fn path, {acc, acc_errors} ->
        relative_path = Path.relative_to(path, directory)
        name = path |> Path.rootname() |> Path.basename()

        case Map.has_key?(acc, name) do
          true ->
            {acc, [duplicate_error(type, loader_module, path, name) | acc_errors]}

          false ->
            read_asset_file(acc, acc_errors, type, loader_module, path, relative_path, name)
        end
      end)

    assets =
      assets_by_name
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    %{assets: assets, errors: Enum.reverse(errors)}
  end

  defp type_to_dir_key(:skill), do: :skills
  defp type_to_dir_key(:command), do: :commands
  defp type_to_dir_key(:workflow), do: :workflows

  defp read_asset_file(acc, acc_errors, type, loader_module, path, relative_path, name) do
    case File.read(path) do
      {:ok, body} ->
        case normalize_body(body) do
          {:ok, normalized_body} ->
            asset = %{
              type: type,
              name: name,
              path: path,
              relative_path: relative_path,
              body: normalized_body
            }

            {Map.put(acc, name, asset), acc_errors}

          :error ->
            {acc, [load_error(type, loader_module, path, :invalid_utf8) | acc_errors]}
        end

      {:error, reason} ->
        {acc, [load_error(type, loader_module, path, reason) | acc_errors]}
    end
  end

  defp normalize_body(body) when is_binary(body) do
    if String.valid?(body), do: {:ok, body}, else: :error
  end

  defp duplicate_error(type, loader_module, path, name) do
    load_error(type, loader_module, path, {:duplicate_name, name})
  end

  defp load_error(type, loader_module, path, reason) do
    %{
      type: type,
      loader: loader_module,
      path: path,
      reason: reason
    }
  end
end
