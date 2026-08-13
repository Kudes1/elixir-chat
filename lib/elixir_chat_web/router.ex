defmodule ElixirChatWeb.Router do
  use ElixirChatWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug ElixirChatWeb.Plugs.EnsureGuest
    plug :fetch_live_flash
    plug :put_root_layout, html: {ElixirChatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ElixirChatWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :guest do
      live "/channels", ChatLive, :index
      live "/channels/:id", ChatLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", ElixirChatWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:elixir_chat, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ElixirChatWeb.Telemetry
    end
  end
end
