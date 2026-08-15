defmodule ElixirChatWeb.ChatLive.Components do
  use ElixirChatWeb, :html

  attr :channels, :list, required: true
  attr :channel, :any, required: true
  attr :direct_conversation_id, :integer, default: nil
  attr :direct_conversations, :list, required: true
  attr :direct_search_open?, :boolean, required: true
  attr :direct_search_form, :any, required: true
  attr :direct_search_results, :list, required: true
  attr :channel_catalog_open?, :boolean, required: true
  attr :current_user, :any, required: true
  attr :visitor_name, :string, required: true

  def sidebar(assigns) do
    ~H"""
    <aside
      id="chat-sidebar"
      class="chat-sidebar sidebar-sections-pending"
      phx-hook="SidebarSections"
      phx-window-keydown={close_sidebar()}
      phx-key="escape"
      aria-label="Навигация чата"
    >
      <header id="workspace-brand" class="sidebar-brand">
        <p class="sidebar-eyebrow">Рабочее пространство</p>
        <h1>Orbit</h1>
      </header>
      <nav id="channel-navigation" class="channel-navigation" aria-label="Навигация чата">
        <section id="channels-section" class="sidebar-section">
          <div class="sidebar-section-header">
            <button
              id="channels-toggle"
              type="button"
              class="sidebar-section-toggle"
              data-sidebar-toggle="channels"
              aria-expanded="true"
              aria-controls="channel-list"
            >
              <.icon name="hero-chevron-down" class="sidebar-section-chevron size-3" />
              <span class="sidebar-section-title">Каналы</span>
            </button>
            <button
              id="open-channel-catalog"
              type="button"
              class="sidebar-section-action"
              phx-click="open_channel_catalog"
              aria-label="Открыть каталог каналов"
              aria-expanded={to_string(@channel_catalog_open?)}
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
          </div>
          <div id="channel-list" class="channel-list" data-sidebar-content="channels">
            <.link
              :for={channel <- @channels}
              id={"channel-#{channel.id}"}
              class={[
                "channel-link",
                @channel && is_nil(@direct_conversation_id) && channel.id == @channel.id && "selected"
              ]}
              patch={~p"/channels/#{channel.public_id}"}
              phx-click={close_sidebar()}
            >
              <span aria-hidden="true">#</span><span class="channel-name">{channel.name}</span>
            </.link>
          </div>
        </section>
        <section id="direct-messages-section" class="sidebar-section direct-messages-section">
          <div class="sidebar-section-header">
            <button
              id="direct-messages-toggle"
              type="button"
              class="sidebar-section-toggle"
              data-sidebar-toggle="directs"
              aria-expanded="true"
              aria-controls="direct-messages-content"
            >
              <.icon name="hero-chevron-down" class="sidebar-section-chevron size-3" />
              <span class="sidebar-section-title">Личные сообщения</span>
            </button>
            <button
              id="open-direct-search"
              type="button"
              class="sidebar-section-action"
              data-open-direct-search
              phx-click="open_direct_search"
              aria-label="Начать личный диалог"
              title="Начать личный диалог"
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
          </div>
          <div id="direct-messages-content" data-sidebar-content="directs">
            <div :if={@direct_search_open?} id="direct-search-panel" class="direct-search-panel">
              <div class="direct-search-heading">
                <strong>Новый диалог</strong>
                <button
                  id="close-direct-search"
                  type="button"
                  phx-click="close_direct_search"
                  aria-label="Закрыть поиск"
                ><.icon name="hero-x-mark" class="size-4" /></button>
              </div>
              <.form
                for={@direct_search_form}
                id="direct-search-form"
                phx-change="search_direct_users"
              >
                <.input
                  field={@direct_search_form[:query]}
                  id="direct-search-query"
                  type="search"
                  label="Поиск пользователя"
                  placeholder="Имя или @логин"
                  autocomplete="off"
                  phx-debounce="200"
                  phx-mounted={JS.focus()}
                />
              </.form>
              <div id="direct-search-results" class="direct-search-results">
                <button
                  :for={user <- @direct_search_results}
                  id={"direct-user-#{user.id}"}
                  type="button"
                  class="direct-user-result"
                  phx-click="start_direct"
                  phx-value-user-id={user.id}
                >
                  <.user_avatar name={user.display_name} user_id={user.id} class="direct-avatar" />
                  <span>
                    <strong>{user.display_name}</strong><small>
                      @{user.login}<span :if={user.online?}> · в сети</span>
                    </small>
                  </span>
                </button>
                <p :if={@direct_search_results == []} class="direct-search-empty">
                  Пользователи не найдены
                </p>
              </div>
            </div>
            <div id="direct-conversation-list" class="channel-list direct-conversation-list">
              <.link
                :for={item <- @direct_conversations}
                :key={item.id}
                id={"direct-conversation-#{item.id}"}
                class={["channel-link direct-link", item.id == @direct_conversation_id && "selected"]}
                patch={~p"/direct/#{item.public_id}"}
                phx-click={close_sidebar()}
              >
                <.user_avatar
                  name={item.other_user.display_name}
                  user_id={item.other_user.id}
                  class="direct-avatar"
                />
                <span class="direct-link-details">
                  <strong>{item.other_user.display_name}</strong>
                  <small>@{item.other_user.login}<span :if={item.other_user.disabled_at}> · отключён</span></small>
                </span>
              </.link>
            </div>
            <p class="direct-list-empty">Пока нет личных диалогов</p>
          </div>
        </section>
      </nav>
      <footer id="current-user" class="sidebar-profile">
        <.user_avatar name={@visitor_name} user_id={@current_user.id} class="profile-avatar" />
        <div class="profile-details">
          <strong>{@visitor_name}</strong><small id="current-user-login" class="current-user-login">@{@current_user.login}</small>
        </div>
        <.link
          href={~p"/logout"}
          method="delete"
          id="logout-link"
          class="logout-link"
          aria-label="Выйти из Orbit"
        >Выйти</.link>
      </footer>
    </aside>
    """
  end

  attr :channel, :any, required: true
  attr :other_user, :any, default: nil
  attr :online_count, :integer, required: true
  attr :current_user, :any, required: true

  def conversation_header(assigns) do
    ~H"""
    <header class="conversation-header">
      <button
        id="sidebar-toggle"
        type="button"
        class="mobile-sidebar-toggle"
        aria-label="Открыть навигацию"
        aria-controls="chat-sidebar"
        aria-expanded="false"
        phx-click={open_sidebar()}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
      <%= if @other_user do %>
        <div class="channel-heading direct-heading">
          <.user_avatar
            name={@other_user.display_name}
            user_id={@other_user.id}
            class="header-avatar"
          />
          <div>
            <h2 class="channel-title">{@other_user.display_name}</h2><p>
              @{@other_user.login}<span :if={@other_user.disabled_at}> · пользователь отключён</span>
            </p>
          </div>
        </div>
      <% else %>
        <div class="channel-heading">
          <h2 class="channel-title"><span aria-hidden="true">#</span> {@channel.name}</h2><p>
            {@channel.description || "Командный разговор"}
          </p>
        </div>
      <% end %>
      <div class="channel-header-actions">
        <span class="online-indicator"><i></i>{@online_count} в сети</span>
        <button
          id="open-message-search"
          type="button"
          class="channel-action"
          phx-click="open_message_search"
          aria-label="Поиск сообщений"
        ><.icon name="hero-magnifying-glass" class="size-5" /></button>
        <button
          :if={is_nil(@other_user)}
          id="open-channel-settings"
          type="button"
          class="channel-action"
          phx-click="open_channel_settings"
          aria-label="Настройки канала"
        ><.icon name="hero-cog-6-tooth" class="size-5" /></button>
      </div>
    </header>
    """
  end

  attr :form, :any, required: true
  attr :channels, :list, required: true

  def channel_catalog(assigns) do
    ~H"""
    <div
      id="channel-catalog"
      class="channel-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="channel-catalog-title"
    >
      <section class="channel-modal" phx-window-keydown="close_channel_catalog" phx-key="escape">
        <header>
          <h2 id="channel-catalog-title">Каталог каналов</h2>
          <button
            id="close-channel-catalog"
            type="button"
            phx-click="close_channel_catalog"
            aria-label="Закрыть каталог"
          ><.icon name="hero-x-mark" class="size-5" /></button>
        </header>
        <.form
          for={@form}
          id="create-channel-form"
          phx-change="validate_channel"
          phx-submit="create_channel"
        >
          <.input
            field={@form[:name]}
            id="new-channel-name"
            label="Название"
            placeholder="team-updates"
            autocomplete="off"
          />
          <.input
            field={@form[:description]}
            id="new-channel-description"
            label="Описание"
            type="textarea"
          />
          <.input
            field={@form[:kind]}
            id="new-channel-kind"
            label="Доступ"
            type="select"
            options={[{"Публичный", :public}, {"Приватный", :private}]}
          />
          <button id="create-channel" type="submit" class="channel-primary-action">Создать канал</button>
        </.form>
        <div id="available-channel-list" class="available-channel-list">
          <article :for={channel <- @channels} id={"available-channel-#{channel.id}"}>
            <div>
              <strong>#{channel.name}</strong><p>{channel.description || "Без описания"}</p>
            </div>
            <button
              id={"join-channel-#{channel.id}"}
              type="button"
              phx-click="join_channel"
              phx-value-channel-id={channel.id}
            >Вступить</button>
          </article>
          <p :if={@channels == []} id="available-channels-empty">Нет новых публичных каналов.</p>
        </div>
      </section>
    </div>
    """
  end

  attr :channel, :any, required: true
  attr :current_user, :any, required: true
  attr :form, :any, required: true
  attr :memberships, :list, required: true
  attr :invite_form, :any, required: true
  attr :invite_results, :list, required: true

  def channel_settings(assigns) do
    ~H"""
    <div
      id="channel-settings"
      class="channel-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="channel-settings-title"
    >
      <section class="channel-modal" phx-window-keydown="close_channel_settings" phx-key="escape">
        <header>
          <h2 id="channel-settings-title">Настройки #<span>{@channel.name}</span></h2>
          <button
            id="close-channel-settings"
            type="button"
            phx-click="close_channel_settings"
            aria-label="Закрыть настройки"
          ><.icon name="hero-x-mark" class="size-5" /></button>
        </header>
        <section
          :if={@channel.owner_id != @current_user.id}
          id="channel-details"
          class="channel-details"
          aria-label="Информация о канале"
        >
          <div>
            <strong>Описание</strong>
            <p>{@channel.description || "Описание не добавлено"}</p>
          </div>
          <div>
            <strong>Доступ</strong>
            <p>{if @channel.kind == :public, do: "Публичный канал", else: "Приватный канал"}</p>
          </div>
        </section>
        <.form
          :if={@channel.owner_id == @current_user.id}
          for={@form}
          id="edit-channel-form"
          phx-submit="update_channel"
        >
          <.input
            field={@form[:name]}
            id="edit-channel-name"
            label="Название"
            disabled={@channel.is_general}
          />
          <.input
            field={@form[:description]}
            id="edit-channel-description"
            label="Описание"
            type="textarea"
          />
          <.input
            field={@form[:kind]}
            id="edit-channel-kind"
            label="Доступ"
            type="select"
            disabled={@channel.is_general}
            options={[{"Публичный", :public}, {"Приватный", :private}]}
          />
          <button id="update-channel" type="submit" class="channel-primary-action">Сохранить</button>
        </.form>
        <div :if={@channel.kind == :private} id="channel-invite-panel">
          <.form for={@invite_form} id="invite-search-form" phx-change="search_invitable_users">
            <.input
              field={@invite_form[:query]}
              id="invite-search-query"
              type="search"
              label="Добавить участника"
              placeholder="Имя или @логин"
              phx-debounce="200"
              autocomplete="off"
            />
          </.form>
          <button
            :for={user <- @invite_results}
            id={"invite-user-#{user.id}"}
            type="button"
            class="member-row"
            phx-click="invite_member"
            phx-value-user-id={user.id}
          >{user.display_name} <small>@{user.login}<span :if={user.online?}> · в сети</span></small></button>
        </div>
        <section
          id="channel-members"
          class="channel-members-section"
          aria-labelledby="channel-members-title"
        >
          <header class="channel-members-heading">
            <h3 id="channel-members-title">Участники канала</h3>
            <span>{length(@memberships)}</span>
          </header>
          <div
            id="channel-member-list"
            class="channel-member-list"
            role="list"
            aria-label="Список участников канала"
            tabindex="0"
          >
            <div
              :for={membership <- @memberships}
              id={"channel-member-#{membership.user.id}"}
              class="channel-member-row"
              role="listitem"
            >
              <.user_avatar
                name={membership.user.display_name}
                user_id={membership.user.id}
                class="channel-member-avatar"
              />
              <span class="channel-member-identity">
                <strong>{membership.user.display_name}</strong>
                <small>@{membership.user.login}</small>
              </span>
              <em :if={membership.user.id == @channel.owner_id}>администратор</em>
              <div
                :if={@channel.owner_id == @current_user.id && membership.user.id != @current_user.id}
                class="channel-member-actions"
              >
                <button
                  id={"transfer-owner-#{membership.user.id}"}
                  type="button"
                  phx-click="transfer_ownership"
                  phx-value-user-id={membership.user.id}
                  data-confirm="Передать владение этим каналом?"
                  title="Передать владение"
                  aria-label={"Передать владение пользователю #{membership.user.display_name}"}
                ><.icon name="hero-key" class="size-4" /></button>
                <button
                  :if={@channel.kind == :private}
                  id={"remove-member-#{membership.user.id}"}
                  type="button"
                  phx-click="remove_member"
                  phx-value-user-id={membership.user.id}
                  data-confirm="Удалить участника из канала?"
                  title="Удалить из канала"
                  aria-label={"Удалить пользователя #{membership.user.display_name} из канала"}
                ><.icon name="hero-user-minus" class="size-4" /></button>
              </div>
            </div>
          </div>
        </section>
        <button
          :if={@channel.owner_id != @current_user.id && !@channel.is_general}
          id="leave-channel"
          type="button"
          class="channel-danger-action"
          phx-click="leave_channel"
          data-confirm="Покинуть этот канал?"
        >Выйти из канала</button>
        <button
          :if={@channel.owner_id == @current_user.id && !@channel.is_general}
          id="archive-channel"
          type="button"
          class="channel-danger-action"
          phx-click="archive_channel"
          data-confirm="Архивировать канал? История сохранится, но доступ будет закрыт."
        >Архивировать канал</button>
      </section>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :highlighted_message_id, :integer, default: nil

  def message(assigns) do
    ~H"""
    <article
      id={"messages-#{@item.id}"}
      class={[
        "message",
        @item.continuation? && "message-continuation",
        @highlighted_message_id == @item.id && "message-highlighted"
      ]}
    >
      <.user_avatar
        :if={!@item.continuation?}
        name={@item.message.author_name}
        user_id={@item.message.user_id}
        class="message-avatar"
      />
      <time :if={@item.continuation?} class="message-continuation-time">{relative_time(
        @item.message.inserted_at
      )}</time>
      <div class="message-content">
        <div :if={!@item.continuation?} class="message-meta">
          <strong>{@item.message.author_name}</strong>
          <button
            :if={@item.message.user}
            id={"message-login-#{@item.message.id}"}
            type="button"
            class="message-author-login"
            phx-click="insert_mention"
            phx-value-login={@item.message.user.login}
            aria-label={"Упомянуть @#{@item.message.user.login}"}
          >@{@item.message.user.login}</button>
          <span class="message-meta-separator">·</span><time>{relative_time(@item.message.inserted_at)}</time>
        </div>
        <.message_body body={@item.message.body} />
      </div>
    </article>
    """
  end

  attr :form, :any, required: true
  attr :channel, :any, required: true
  attr :other_user, :any, default: nil

  def composer(assigns) do
    ~H"""
    <div
      :if={@other_user && @other_user.disabled_at}
      id="direct-recipient-disabled"
      class="composer-disabled"
    >
      Этот пользователь отключён. История доступна только для чтения.
    </div>
    <.form
      :if={is_nil(@other_user) || is_nil(@other_user.disabled_at)}
      for={@form}
      id="message-form"
      phx-submit="send_message"
      class="composer"
    >
      <.input
        field={@form[:body]}
        id="message-body"
        type="textarea"
        class="chat-composer-input"
        rows="1"
        autocomplete="off"
        placeholder={
          if @other_user, do: "Написать @#{@other_user.login}", else: "Написать в ##{@channel.name}"
        }
        aria-label="Сообщение"
        phx-hook="MessageComposer"
      />
      <button id="send-message" type="submit" aria-label="Отправить сообщение"><.icon
        name="hero-arrow-up"
        class="size-4"
      /></button>
    </.form>
    """
  end

  attr :name, :string, required: true
  attr :user_id, :integer, default: nil
  attr :class, :any, required: true

  def user_avatar(assigns) do
    assigns = assign(assigns, :variant, avatar_variant(assigns.user_id, assigns.name))

    ~H"""
    <div class={[@class, "avatar-variant-#{@variant}"]}>{initials(@name)}</div>
    """
  end

  def avatar_variant(user_id, _name) when is_integer(user_id), do: rem(user_id, 4)

  def avatar_variant(nil, name) do
    name |> String.trim() |> String.downcase() |> :erlang.phash2(4)
  end

  def initials(name) do
    name
    |> String.split()
    |> Enum.map_join("", &String.first/1)
    |> String.slice(0, 2)
    |> String.upcase()
  end

  def relative_time(datetime), do: Calendar.strftime(datetime, "%H:%M")

  def message_snippet(body) do
    normalized = String.replace(body, ~r/\s+/u, " ")

    if String.length(normalized) > 160,
      do: String.slice(normalized, 0, 160) <> "…",
      else: normalized
  end

  attr :body, :string, required: true

  def message_body(assigns) do
    ~H"""
    <p>
      <span
        :for={{kind, fragment} <- mention_fragments(@body)}
        class={kind == :mention && "message-mention"}
      >{fragment}</span>
    </p>
    """
  end

  def mention_fragments(body) do
    ~r/(@[a-z0-9._-]+)/
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.map(fn fragment ->
      if Regex.match?(~r/^@[a-z0-9._-]+$/, fragment),
        do: {:mention, fragment},
        else: {:text, fragment}
    end)
  end

  def open_sidebar(js \\ %JS{}) do
    js
    |> JS.show(to: "#sidebar-overlay")
    |> JS.add_class("sidebar-open", to: "#chat-sidebar")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#sidebar-toggle")
    |> JS.focus_first(to: "#chat-sidebar")
  end

  def close_sidebar(js \\ %JS{}) do
    js
    |> JS.hide(to: "#sidebar-overlay")
    |> JS.remove_class("sidebar-open", to: "#chat-sidebar")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#sidebar-toggle")
  end
end
