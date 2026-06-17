defmodule SvmmWeb.PageController do
  use SvmmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
