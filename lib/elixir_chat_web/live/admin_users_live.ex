defmodule ElixirChatWeb.AdminUsersLive do
  use ElixirChatWeb, :live_view
  alias ElixirChat.Accounts
  alias ElixirChatWeb.InvitationPath

  def mount(_, _, socket) do
    {users, has_more?} = Accounts.list_users(socket.assigns.current_scope, nil)

    {:ok,
     socket
     |> assign(:page_title, "Пользователи")
     |> assign(:invite_path, nil)
     |> assign(:invite_form, to_form(%{}, as: :invite))
     |> assign(:users_cursor, List.last(users))
     |> assign(:has_more_users?, has_more?)
     |> stream(:users, users)}
  end

  def handle_event("invite", %{"invite" => attrs}, socket) do
    case Accounts.create_registration_invitation(socket.assigns.current_scope, attrs) do
      {:ok, _, token} -> {:noreply, assign(socket, :invite_path, InvitationPath.for_token(token))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Проверьте логин и имя.")}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with {:ok, user} <- Accounts.get_managed_user(socket.assigns.current_scope, id),
         disabled_at <- if(user.disabled_at, do: nil, else: DateTime.utc_now(:second)),
         {:ok, user} <-
           Accounts.update_user(socket.assigns.current_scope, user, %{disabled_at: disabled_at}) do
      {:noreply, stream_insert(socket, :users, user)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Операция запрещена.")}
    end
  end

  def handle_event("reset", %{"id" => id}, socket) do
    with {:ok, user} <- Accounts.get_managed_user(socket.assigns.current_scope, id),
         {:ok, _, token} <- Accounts.create_password_reset(socket.assigns.current_scope, user) do
      {:noreply, assign(socket, :invite_path, InvitationPath.for_token(token))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Нельзя выдать ссылку сброса.")}
    end
  end

  def handle_event("load_more_users", _params, socket) do
    {users, has_more?} =
      Accounts.list_users(socket.assigns.current_scope, socket.assigns.users_cursor)

    socket = Enum.reduce(users, socket, &stream_insert(&2, :users, &1))

    {:noreply,
     socket
     |> assign(:users_cursor, List.last(users) || socket.assigns.users_cursor)
     |> assign(:has_more_users?, has_more?)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main class="mx-auto max-w-4xl p-8">
        <h1 class="text-3xl font-bold">Пользователи Orbit</h1>
        <.form
          for={@invite_form}
          id="invite-user-form"
          phx-submit="invite"
          class="my-8 grid gap-3 md:grid-cols-3"
        >
          <.input field={@invite_form[:login]} id="invite-login" label="Логин" required />
          <.input
            field={@invite_form[:display_name]}
            id="invite-name"
            label="Отображаемое имя"
            required
          />
          <button id="create-invitation" class="btn btn-primary self-end">Создать приглашение</button>
        </.form>
        <div :if={@invite_path} id="one-time-link" class="alert alert-warning break-all">
          Скопируйте путь сейчас — он больше не показывается. Добавьте его к адресу нужного домена: {@invite_path}
        </div>
        <div id="users" phx-update="stream" class="mt-8 space-y-3">
          <div
            :for={{id, user} <- @streams.users}
            id={id}
            class="flex items-center justify-between rounded border p-4"
          >
            <div>
              <strong>{user.display_name}</strong>
              <span class="opacity-60">@{user.login} · {user.role}</span>
            </div>
            <div :if={user.role == :user} class="flex gap-2">
              <button
                id={"reset-#{user.id}"}
                phx-click="reset"
                phx-value-id={user.id}
                class="btn btn-sm"
              >Сброс</button>
              <button
                id={"toggle-#{user.id}"}
                phx-click="toggle"
                phx-value-id={user.id}
                class="btn btn-sm"
              >{if user.disabled_at, do: "Включить", else: "Заблокировать"}</button>
            </div>
          </div>
        </div>
        <button
          :if={@has_more_users?}
          id="load-more-users"
          type="button"
          phx-click="load_more_users"
          class="btn mt-4 w-full"
        >Показать ещё</button>
      </main>
    </Layouts.app>
    """
  end
end
