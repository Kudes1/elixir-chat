defmodule ElixirChatWeb.Router do
  use ElixirChatWeb, :router
  import ElixirChatWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ElixirChatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ElixirChatWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/invitation/:token", InvitationController, :capture
    get "/invitation", InvitationController, :new
    post "/invitation", InvitationController, :create

    live_session :authenticated, on_mount: [{ElixirChatWeb.UserAuth, :ensure_authenticated}] do
      live "/channels", ChatLive, :index
      live "/channels/:public_id", ChatLive, :show
      live "/direct/:public_id", ChatLive, :direct
    end
  end

  scope "/", ElixirChatWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]
    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", ElixirChatWeb do
    pipe_through [:browser, :require_authenticated_user]
    delete "/logout", SessionController, :delete
  end

  scope "/admin", ElixirChatWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]
    get "/reauth", AdminSessionController, :new
    post "/reauth", AdminSessionController, :create
  end

  scope "/admin", ElixirChatWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin, :require_sudo]

    live_session :admin, on_mount: [{ElixirChatWeb.UserAuth, :ensure_admin}] do
      live "/users", AdminUsersLive, :index
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
