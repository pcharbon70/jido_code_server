defmodule JidoCodeServerTest do
  use ExUnit.Case, async: true

  test "root module is available" do
    assert Code.ensure_loaded?(JidoCodeServer)
  end
end
