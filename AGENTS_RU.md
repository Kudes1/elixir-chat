Это веб-приложение, написанное с использованием фреймворка Phoenix.

## Правила проекта

- После завершения всех изменений запускайте алиас `mix precommit` и устраняйте все найденные проблемы.
- Для HTTP-запросов используйте уже включённую библиотеку `:req` (`Req`). **Не используйте** `:httpoison`, `:tesla` или `:httpc`: `Req` является предпочтительным HTTP-клиентом Phoenix.

### Правила Phoenix v1.8

- **Всегда** начинайте шаблоны LiveView с `<Layouts.app flash={@flash} ...>`, который оборачивает всё внутреннее содержимое.
- Модуль `MyAppWeb.Layouts` уже алиасирован в `my_app_web.ex`, поэтому добавлять алиас повторно не нужно.
- Если возникает ошибка об отсутствии assign `current_scope`:
  - не соблюдены правила Authenticated Routes либо `current_scope` не передан в `<Layouts.app>`;
  - **всегда** исправляйте это переносом маршрутов в корректный `live_session` и передачей `current_scope` там, где требуется.
- В Phoenix v1.8 компонент `<.flash_group>` перенесён в модуль `Layouts`. **Запрещено** вызывать `<.flash_group>` вне `layouts.ex`.
- В `core_components.ex` уже импортирован компонент иконок `<.icon name="hero-x-mark" class="w-5 h-5"/>`. **Всегда** используйте `<.icon>` для иконок; никогда не используйте модули `Heroicons` или аналоги.
- Если доступен импортированный компонент `<.input>` из `core_components.ex`, **всегда** используйте его для полей формы — это уменьшает количество ошибок.
- При переопределении классов по умолчанию (`<.input class="myclass px-2 py-1 rounded-lg">`) они больше не наследуются: собственные классы должны полностью оформлять поле.

### Правила JS и CSS

- **Используйте классы Tailwind CSS и собственные CSS-правила** для аккуратных, отзывчивых интерфейсов.
- Tailwindcss v4 **больше не требует `tailwind.config.js`** и использует в `app.css` такой синтаксис:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Всегда сохраняйте этот синтаксис импорта** в `app.css` для проектов, созданных через `phx.new`.
- Никогда не используйте `@apply` в обычном CSS.
- **Всегда** вручную создавайте компоненты на Tailwind вместо daisyUI, чтобы интерфейс оставался оригинальным.
- По умолчанию поддерживаются **только** бандлы `app.js` и `app.css`:
  - в layout нельзя подключать внешние скрипты через `src` или стили через `href`;
  - vendor-зависимости нужно импортировать в `app.js` и `app.css`;
  - никогда не размещайте в шаблонах встроенные теги `<script>custom js</script>`.

### Правила UI/UX и дизайна

- Создавайте интерфейсы высокого качества с упором на удобство, эстетику и современные принципы дизайна.
- Добавляйте ненавязчивые микро-взаимодействия: эффекты наведения, плавные переходы.
- Поддерживайте чистую типографику, сбалансированные отступы и компоновку.
- Уделяйте внимание деталям: состояниям загрузки, эффектам наведения и плавным переходам страниц.

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Правила Elixir

- Списки Elixir **не поддерживают доступ по индексу через синтаксис Access**.

  **Никогда не делайте так (некорректно):**

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Вместо этого **всегда** используйте `Enum.at`, сопоставление с образцом или `List`:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Переменные Elixir неизменяемы, хотя их можно повторно связывать. Поэтому результат блоков `if`, `case`, `cond` и т. п. необходимо привязать к переменной, если он будет использоваться; нельзя рассчитывать на повторное связывание только внутри блока:

      # НЕКОРРЕКТНО: связывание выполняется внутри if, а результат не присваивается
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # КОРРЕКТНО: результат присваивается новой переменной
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Никогда** не размещайте несколько модулей в одном файле: это может привести к циклическим зависимостям и ошибкам компиляции.
- **Никогда** не используйте map-access (`changeset[:field]`) для структур, поскольку они обычно не реализуют `Access`. Обращайтесь к полям напрямую (`my_struct.field`) либо через подходящий высокоуровневый API, например `Ecto.Changeset.get_field/2` для changeset.
- Стандартной библиотеки Elixir достаточно для работы с датой и временем. Используйте интерфейсы `Time`, `Date`, `DateTime` и `Calendar`. **Не устанавливайте** дополнительные зависимости, если это не запрошено явно или не нужно для разбора даты/времени (допустим `date_time_parser`).
- Не применяйте `String.to_atom/1` к пользовательскому вводу: это создаёт риск утечки памяти.
- Имена предикатов не должны начинаться с `is_`; они должны оканчиваться на `?`. Имена вида `is_thing` оставляйте для guard-выражений.
- Встроенным примитивам OTP, таким как `DynamicSupervisor` и `Registry`, требуется имя в child spec: `{DynamicSupervisor, name: MyApp.MyDynamicSup}`. Затем используйте `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`.
- Для конкурентного обхода с обратным давлением используйте `Task.async_stream(collection, callback, options)`. В большинстве случаев указывайте `timeout: :infinity`.

## Правила Mix

- Перед запуском задачи читайте её документацию и параметры: `mix help task_name`.
- Для отладки теста запускайте конкретный файл через `mix test test/my_test.exs`; все ранее упавшие тесты — через `mix test --failed`.
- `mix deps.clean --all` почти никогда не требуется. **Не используйте** его без веской причины.

## Правила тестирования

- **Всегда** запускайте процессы в тестах через `start_supervised!/1`: это гарантирует очистку между тестами.
- Не используйте `Process.sleep/1` и `Process.alive?/1`.
  - Вместо ожидания завершения процесса через sleep используйте `Process.monitor/1` и проверяйте сообщение DOWN:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Вместо sleep для синхронизации перед следующим вызовом используйте `_ = :sys.get_state/1`, чтобы убедиться, что процесс обработал предыдущее сообщение.
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Правила Phoenix

- Помните, что блоки `scope` в маршрутизаторе Phoenix могут задавать алиас, добавляемый ко всем маршрутам внутри scope. Учитывайте это, чтобы не продублировать префикс модуля.

- Для определений маршрутов **никогда** не нужен собственный `alias`: его предоставляет `scope`:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  Этот маршрут `UserLive` указывает на модуль `AppWeb.Admin.UserLive`.

- `Phoenix.View` больше не нужен и не включён в Phoenix; не используйте его.
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Правила Ecto

- **Всегда** preload-ите Ecto-ассоциации в запросах, если они используются в шаблонах, например `message.user.email`.
- При написании `seeds.exs` не забывайте импортировать `Ecto.Query` и другие вспомогательные модули.
- Поля `Ecto.Schema` всегда имеют тип `:string`, даже для текстовых колонок: `field :name, :string`.
- `Ecto.Changeset.validate_number/2` **НЕ ПОДДЕРЖИВАЕТ** опцию `:allow_nil`. По умолчанию валидация выполняется только при наличии изменения и ненулевом значении, поэтому эта опция не требуется.
- Для доступа к полям changeset **обязательно** используйте `Ecto.Changeset.get_field(changeset, :field)`.
- Поля, устанавливаемые программно, например `user_id`, нельзя включать в `cast` и аналогичные вызовы по соображениям безопасности. Устанавливайте их явно при создании структуры.
- **Всегда** создавайте миграции командой `mix ecto.gen.migration migration_name_using_underscores`, чтобы получить корректную временную метку и соглашения об именовании.
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Правила Phoenix HTML

- Шаблоны Phoenix всегда используют `~H` или файлы `.html.heex` (HEEx); **никогда** не используйте `~E`.
- Для форм **всегда** применяйте импортированные `Phoenix.Component.form/1` и `Phoenix.Component.inputs_for/1`. Не используйте устаревшие `Phoenix.HTML.form_for` и `Phoenix.HTML.inputs_for`.
- При создании формы **всегда** используйте импортированный `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` и `<.form for={@form} id="msg-form">`), затем обращайтесь к полям как `@form[:field]`.
- **Всегда** задавайте уникальные DOM ID ключевым элементам (формам, кнопкам и т. п.), чтобы использовать их в тестах: `<.form for={@form} id="product-form">`.
- Для общих импортов шаблонов добавляйте import/alias в блок `html_helpers` файла `my_app_web.ex`: они станут доступны во всех LiveView, LiveComponent и модулях с `use MyAppWeb, :html` (замените `my_app` на имя приложения).

- Elixir поддерживает `if/else`, но **не поддерживает `if/else if` или `if/elsif`**. Для нескольких условий всегда используйте `cond` или `case`.

  **Никогда не делайте так (некорректно):**

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Вместо этого:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx требует специальной аннотации, чтобы вставлять буквальные фигурные скобки `{` и `}`. Если текстовый пример кода в `<pre>` или `<code>` содержит скобки, добавьте родительскому тегу `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Внутри такого тега можно использовать `{` и `}` без экранирования; динамические Elixir-выражения по-прежнему доступны через `<%= ... %>`.

- Атрибуты `class` в HEEx поддерживают списки, но нужно **всегда** использовать синтаксис `[...]`. Используйте его для нескольких и условных классов:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  Условие `if` внутри `{...}` всегда заключайте в скобки, как выше. Следующий вариант некорректен (нет `[` и `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- Для генерации содержимого никогда не используйте `<% Enum.each %>` или другие не-`for` comprehensions. Используйте `<%= for item <- @collection do %>`.
- HTML-комментарии HEEx имеют вид `<%!-- comment --%>`. Всегда используйте именно этот синтаксис для комментариев в шаблонах.
- HEEx поддерживает интерполяцию через `{...}` и `<%= ... %>`, но `<%= %>` работает только внутри тела тега. В атрибутах и для значений в теле тега всегда используйте `{...}`. Блоковые конструкции (`if`, `cond`, `case`, `for`) внутри тела тега интерполируйте через `<%= ... %>`.

  **Корректно:**

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  **Некорректно — приложение завершится с синтаксической ошибкой:**

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Правила Phoenix LiveView

- **Никогда** не используйте устаревшие `live_redirect` и `live_patch`. В шаблонах используйте `<.link navigate={href}>` и `<.link patch={href}>`, а в LiveView — `push_navigate` и `push_patch`.
- Избегайте LiveComponent, если для них нет сильной и конкретной причины.
- LiveView должны называться по схеме `AppWeb.WeatherLive`, с суффиксом `Live`. В маршрутах scope `:browser` уже алиасирован модулем `AppWeb`, поэтому достаточно `live "/weather", WeatherLive`.

### Потоки LiveView

- **Всегда** используйте потоки LiveView для коллекций вместо обычных списков, чтобы избежать роста памяти и аварийного завершения:
  - добавить N элементов: `stream(socket, :messages, [new_msg])`;
  - сбросить поток новыми элементами: `stream(socket, :messages, [new_msg], reset: true)` (например, при фильтрации);
  - добавить элемент в начало: `stream(socket, :messages, [new_msg], at: -1)`;
  - удалить элемент: `stream_delete(socket, :messages, msg)`.

- При использовании `stream/3` шаблон должен: 1) задавать родителю `phx-update="stream"` и DOM ID, например `id="messages"`; 2) использовать коллекцию `@streams.stream_name` и ID каждого дочернего элемента. Например:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- Потоки LiveView *не перечисляемы*, поэтому нельзя вызывать для них `Enum.filter/2` или `Enum.reject/2`. Для фильтрации, удаления части или обновления получите данные заново и повторно передайте весь поток с `reset: true`:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # Повторно получаем сообщения по фильтру
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # Сбрасываем поток
         |> stream(:messages, messages, reset: true)}
      end

- Потоки LiveView *не поддерживают подсчёт и пустые состояния*. Для счётчика храните отдельный assign. Для пустого состояния используйте классы Tailwind:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  Это работает, только если пустое состояние — единственный HTML-блок рядом с `for` потока.

- При обновлении assign, который меняет содержимое элементов потока, **обязательно** повторно передайте эти элементы в поток вместе с обновлённым assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # Вставляем заново, чтобы переключатель @editing_message_id применился к элементу потока
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  В шаблоне:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Режим редактирования --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- Никогда не используйте устаревшие `phx-update="append"` или `phx-update="prepend"` для коллекций.

### Взаимодействие LiveView с JavaScript

- Если используете `phx-hook="MyHook"` и JS-hook самостоятельно управляет DOM, необходимо также задать `phx-update="ignore"`.
- Вместе с `phx-hook` **всегда** указывайте уникальный DOM ID, иначе возникнет ошибка компилятора.

Hooks LiveView бывают двух видов: 1) colocated JS hooks для встроенных в HEEx скриптов; 2) внешние аннотации `phx-hook`, где литералы JavaScript-объектов передаются в конструктор `LiveSocket`.

#### Встроенные colocated JS hooks

Никогда не вставляйте в HEEx обычные теги `<script>`: они несовместимы с LiveView. Вместо этого **всегда используйте тег скрипта colocated JS hook** с `:type={Phoenix.LiveView.ColocatedHook}`:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- Colocated hooks автоматически интегрируются в бандл `app.js`.
- Имена colocated hooks **всегда** должны начинаться с точки: например, `.PhoneNumber`.

#### Внешний `phx-hook`

Внешние JS hooks (`<div id="myhook" phx-hook="MyHook">`) должны находиться в `assets/js/` и передаваться в конструктор `LiveSocket`:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Отправка событий между клиентом и сервером

Если нужно передать клиенту события или данные для обработки hook, используйте `push_event/3`. При отправке события **всегда** возвращайте или повторно связывайте socket:

    # Повторно связываем socket, чтобы сохранить состояние события
    socket = push_event(socket, "my_event", %{...})

    # Либо сразу возвращаем изменённый socket:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Клиент получает такие события через `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server", data));
    }

Клиент также может отправить событие серверу и получить ответ через `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply", reply));
      })
    }

Сервер обрабатывает его так:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### Тесты LiveView

- Для проверок используйте модуль `Phoenix.LiveViewTest` и включённый `LazyHTML`.
- Тесты форм выполняются функциями `render_submit/2` и `render_change/2` из `Phoenix.LiveViewTest`.
- Составляйте пошаговый план тестирования, разбивая основные сценарии на небольшие изолированные файлы. Начните с проверок наличия содержимого, затем добавляйте проверки взаимодействий.
- **Всегда ссылайтесь на ключевые ID** из шаблонов LiveView в функциях `element/2`, `has_element/2` и селекторах.
- Никогда не проверяйте сырой HTML. Используйте `element/2`, `has_element/2` и подобные функции: `assert has_element?(view, "#my-form")`.
- Вместо проверки текста, который может измениться, предпочитайте проверку наличия ключевых элементов.
- Проверяйте результаты, а не детали реализации.
- `Phoenix.Component`, например `<.form>`, может генерировать HTML не так, как предполагается. Тестируйте реальную структуру результата.
- При проблемах с селекторами добавьте отладочный вывод HTML, но ограничивайте его селекторами `LazyHTML`:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Работа с формами

#### Создание формы из параметров

Чтобы создать форму из параметров `handle_event`:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

При передаче map в `to_form/1` считается, что в нём находятся параметры формы со строковыми ключами.

Можно указать имя для вложения параметров:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Создание формы из changeset

При использовании changeset из него извлекаются исходные данные, параметры формы и ошибки; опция `:as` вычисляется автоматически. Например, если есть схема пользователя:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

Создайте changeset и передайте его в `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

После отправки формы параметры будут доступны под ключом `%{"user" => user_params}`.

В шаблоне assign формы передаётся компоненту `<.form>`:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Всегда задавайте форме явный уникальный DOM ID, например `id="todo-form"`.

#### Предотвращение ошибок форм

В LiveView **всегда** используйте форму, назначенную через `to_form/2`, и компонент `<.input>`. В шаблоне обращайтесь к форме так:

    <%!-- ВСЕГДА делайте так (корректно) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

И никогда так:

    <%!-- НИКОГДА не делайте так (некорректно) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- Обращаться к changeset в шаблоне **запрещено**: это вызывает ошибки.
- Никогда не используйте `<.form let={f} ...>`. **Всегда** используйте `<.form for={@form} ...>`, затем обращайтесь к полям как `@form[:field]`. UI всегда должен управляться формой из `to_form/2`, назначенной в модуле LiveView и производной от changeset.
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
