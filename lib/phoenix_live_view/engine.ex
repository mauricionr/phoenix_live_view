defmodule Phoenix.LiveView.Component do
  @moduledoc """
  The struct returned by components in .leex templates.

  This component is never meant to be output directly
  into the template. It should always be handled by
  the diffing algorithm.
  """

  defstruct [:id, :component, :assigns]

  @type t :: %__MODULE__{
          id: binary(),
          component: module(),
          assigns: map()
        }

  defimpl Phoenix.HTML.Safe do
    def to_iodata(%{id: id, component: component}) do
      raise ArgumentError,
            "cannot convert component #{inspect(component)} with id #{inspect(id)} to HTML. " <>
              "A component must always be returned directly as part of a LiveView template"
    end
  end
end

defmodule Phoenix.LiveView.Comprehension do
  @moduledoc """
  The struct returned by for-comprehensions in .leex templates.

  See a description about its fields and use cases
  in `Phoenix.LiveView.Engine` docs.
  """

  defstruct [:static, :dynamics, :fingerprint]

  @type t :: %__MODULE__{
          static: [String.t()],
          dynamics: [
            [
              iodata()
              | Phoenix.LiveView.Rendered.t()
              | Phoenix.LiveView.Comprehension.t()
              | Phoenix.LiveView.Component.t()
            ]
          ],
          fingerprint: integer()
        }

  defimpl Phoenix.HTML.Safe do
    def to_iodata(%Phoenix.LiveView.Comprehension{static: static, dynamics: dynamics}) do
      for dynamic <- dynamics, do: to_iodata(static, dynamic)
    end

    defp to_iodata([static_head | static_tail], [%_{} = struct | dynamic_tail]) do
      dynamic_head = Phoenix.HTML.Safe.to_iodata(struct)
      [static_head, dynamic_head | to_iodata(static_tail, dynamic_tail)]
    end

    defp to_iodata([static_head | static_tail], [dynamic_head | dynamic_tail]) do
      [static_head, dynamic_head | to_iodata(static_tail, dynamic_tail)]
    end

    defp to_iodata([static_head], []) do
      [static_head]
    end
  end
end

defmodule Phoenix.LiveView.Rendered do
  @moduledoc """
  The struct returned by .leex templates.

  See a description about its fields and use cases
  in `Phoenix.LiveView.Engine` docs.
  """

  defstruct [:static, :dynamic, :fingerprint]

  @type t :: %__MODULE__{
          static: [String.t()],
          dynamic: [
            nil
            | iodata()
            | Phoenix.LiveView.Rendered.t()
            | Phoenix.LiveView.Comprehension.t()
            | Phoenix.LiveView.Component.t()
          ],
          fingerprint: integer()
        }

  defimpl Phoenix.HTML.Safe do
    def to_iodata(%Phoenix.LiveView.Rendered{static: static, dynamic: dynamic}) do
      to_iodata(static, dynamic, [])
    end

    def to_iodata(%_{} = struct) do
      Phoenix.HTML.Safe.to_iodata(struct)
    end

    def to_iodata(nil) do
      raise "cannot convert .leex template with change tracking to iodata"
    end

    def to_iodata(other) do
      other
    end

    defp to_iodata([static_head | static_tail], [dynamic_head | dynamic_tail], acc) do
      to_iodata(static_tail, dynamic_tail, [to_iodata(dynamic_head), static_head | acc])
    end

    defp to_iodata([static_head], [], acc) do
      Enum.reverse([static_head | acc])
    end
  end
end

defmodule Phoenix.LiveView.Engine do
  @moduledoc ~S"""
  The `.leex` (Live EEx) template engine that tracks changes.

  On the docs below, we will explain how it works internally.
  For user-facing documentation, see `Phoenix.LiveView`.

  ## Phoenix.LiveView.Rendered

  Whenever you render a `.leex` template, it returns a
  `Phoenix.LiveView.Rendered` structure. This structure has
  three fields: `:static`, `:dynamic` and `:fingerprint`.

  The `:static` field is a list of literal strings. This
  allows the Elixir compiler to optimize this list and avoid
  allocating its strings on every render.

  The `:dynamic` field contains a list of dynamic content.
  Each element in the list is either one of:

    1. iodata - which is the dynamic content
    2. nil - the dynamic content did not change, see "Tracking changes" below
    3. another `Phoenix.LiveView.Rendered` struct, see "Nesting and fingerprinting" below
    4. a `Phoenix.LiveView.Comprehension` struct, see "Comprehensions" below
    4. a `Phoenix.LiveView.Component` struct, see "Component" below

  When you render a `.leex` template, you can convert the
  rendered structure to iodata by intercalating the static
  and dynamic fields, always starting with a static entry
  followed by a dynamic entry. The last entry will always
  be static too. So the following structure:

      %Phoenix.LiveView.Rendered{
        static: ["foo", "bar", "baz"],
        dynamic: ["left", "right"]
      }

  Results in the following content to be sent over the wire
  as iodata:

      ["foo", "left", "bar", "right", "baz"]

  This is also what calling `Phoenix.HTML.Safe.to_iodata/1`
  with a `Phoenix.LiveView.Rendered` structure returns.

  Of course, the benefit of `.leex` templates is exactly
  that you do not need to send both static and dynamic
  segments every time. So let's talk about tracking changes.

  ## Tracking changes

  By default, a `.leex` template does not track changes.
  Change tracking can be enabled by passing a `socket`
  with two keys `:fingerprints` and `:changed`. If
  the `:fingerprints` matches the template fingerprint,
  then the `:changed` map is used. The map should
  contain the name of any changed field as key and the
  boolean true as value. If a field is not listed in
  `:changed`, then it is always considered unchanged.

  If a field is unchanged and `.leex` believes a dynamic
  expression no longer needs to be computed, its value
  in the `dynamic` list will be `nil`. This information
  can be leveraged to avoid sending data to the client.

  ## Nesting and fingerprinting

  `Phoenix.LiveView` also tracks changes across `.leex`
  templates. Therefore, if your view has this:

      <%= render "form.html", assigns %>

  Phoenix will be able to track what is static and dynamic
  across templates, as well as what changed. A rendered
  nested `.leex` template will appear in the `dynamic`
  list as another `Phoenix.LiveView.Rendered` structure,
  which must be handled recursively.

  However, because the rendering of live templates can
  be dynamic in itself, it is important to distinguish
  which `.leex` template was rendered. For example,
  imagine this code:

      <%= if something?, do: render("one.html", assigns), else: render("other.html", assigns) %>

  To solve this, all `Phoenix.LiveView.Rendered` structs
  also contain a fingerprint field that uniquely identifies
  it. If the fingerprints are equal, you have the same
  template, and therefore it is possible to only transmit
  its changes.

  ## Comprehensions

  Another optimization done by `.leex` templates is to
  track comprehensions. If your code has this:

      <%= for point <- @points do %>
        x: <%= point.x %>
        y: <%= point.y %>
      <% end %>

  Instead of rendering all points with both static and
  dynamic parts, it returns a `Phoenix.LiveView.Comprehension`
  struct with the static parts, that are shared across all
  points, and a list of dynamics to be interpolated inside
  the static parts. If `@points` is a list with `%{x: 1, y: 2}`
  and `%{x: 3, y: 4}`, the expression above would return:

      %Phoenix.LiveView.Comprehension{
        static: ["\n  x: ", "\n  y: ", "\n"],
        dynamics: [
          ["1", "2"],
          ["3", "4"]
        ]
      }

  This allows `.leex` templates to drastically optimize
  the data sent by comprehensions, as the static parts
  are emitted once, regardless of the number of items.

  The list of dynamics is always a list of iodatas or components,
  as we don't perform change tracking inside the comprehensions
  themselves. Similarly, comprehensions do not have fingerprints
  because they are only optimized at the root, so conditional
  evaluation, as the one seen in rendering, is not possible.
  The only possible outcome for a dynamic field that returns a
  comprehension is `nil`.

  ## Components

  `.leex` also supports stateful components. Since they are
  stateful, they are always handled lazily by the diff algorithm.
  """

  @behaviour Phoenix.Template.Engine
  @pdict_key {__MODULE__, :fingerprint}

  @impl true
  def compile(path, _name) do
    EEx.compile_file(path, engine: __MODULE__, line: 1, trim: true)
  end

  @behaviour EEx.Engine

  @impl true
  def init(_opts) do
    %{
      static: [],
      dynamic: [],
      vars_count: 0
    }
  end

  @impl true
  def handle_begin(state) do
    %{state | static: [], dynamic: []}
  end

  @impl true
  def handle_end(state) do
    %{static: static, dynamic: dynamic} = state
    safe = {:safe, Enum.reverse(static)}
    {:__block__, [live_rendered: true], Enum.reverse([safe | dynamic])}
  end

  @impl true
  def handle_body(state) do
    {fingerprint, entries} = to_rendered_struct(handle_end(state), true, false, %{}, %{})

    quote do
      require Phoenix.LiveView.Engine

      {fingerprint, prints} =
        Process.get(unquote(@pdict_key)) ||
          case var!(assigns) do
            %{socket: %{fingerprints: fingerprints}} -> fingerprints
            _ -> {nil, %{}}
          end

      changed =
        case var!(assigns) do
          %{socket: %{changed: changed}} when unquote(fingerprint) == fingerprint -> changed
          _ -> nil
        end

      try do
        unquote({:__block__, [], entries})
      after
        Process.delete(unquote(@pdict_key))
      end
    end
  end

  @impl true
  def handle_text(state, text) do
    %{static: static} = state
    %{state | static: [text | static]}
  end

  @impl true
  def handle_expr(state, "=", ast) do
    %{static: static, dynamic: dynamic, vars_count: vars_count} = state
    var = Macro.var(:"arg#{vars_count}", __MODULE__)
    ast = quote do: unquote(var) = unquote(__MODULE__).to_safe(unquote(ast))
    %{state | dynamic: [ast | dynamic], static: [var | static], vars_count: vars_count + 1}
  end

  def handle_expr(state, "", ast) do
    %{dynamic: dynamic} = state
    %{state | dynamic: [ast | dynamic]}
  end

  def handle_expr(state, marker, ast) do
    EEx.Engine.handle_expr(state, marker, ast)
  end

  ## Entry point for rendered structs

  defp to_rendered_struct(expr, check_prints?, tainted_vars, vars, assigns) do
    with {:__block__, [live_rendered: true], entries} <- expr,
         {dynamic, [{:safe, static}]} <- Enum.split(entries, -1) do
      {block, static, dynamic, fingerprint} =
        analyze_static_and_dynamic(static, dynamic, check_prints?, tainted_vars, vars, assigns)

      rendered =
        quote do
          %Phoenix.LiveView.Rendered{
            static: unquote(static),
            dynamic: unquote(dynamic),
            fingerprint: unquote(fingerprint)
          }
        end

      {fingerprint, block ++ [rendered]}
    else
      _ -> :error
    end
  end

  defmacrop to_safe_match(var, ast) do
    quote do
      {:=, [],
       [
         {_, _, __MODULE__} = unquote(var),
         {{:., _, [__MODULE__, :to_safe]}, _, [unquote(ast)]}
       ]}
    end
  end

  defp analyze_static_and_dynamic(static, dynamic, check_prints?, tainted_vars, vars, assigns) do
    {block, _} =
      Enum.map_reduce(dynamic, {0, vars}, fn
        to_safe_match(var, ast), {counter, vars} ->
          {ast, keys, vars} = analyze_and_return_tainted_keys(ast, tainted_vars, vars, assigns)
          live_struct = to_live_struct(ast, tainted_vars, vars, assigns)
          fingerprint_live_struct = maybe_pdict_fingerprint(live_struct, check_prints?, counter)
          {to_conditional_var(keys, var, fingerprint_live_struct), {counter + 1, vars}}

        ast, {counter, vars} ->
          {ast, _, vars, _} = analyze(ast, tainted_vars, vars, assigns)
          {ast, {counter, vars}}
      end)

    {static, dynamic} = bins_and_vars(static)
    {block, static, dynamic, static_fingerprint(static)}
  end

  ## Optimize possible expressions into live structs (rendered / comprehensions)

  defp to_live_struct({:live_component, meta, [_ | _] = args} = expr, tainted_vars, vars, assigns) do
    case Enum.split(args, -1) do
      {args, [[do: do_block]]} ->
        {args, tainted_vars, vars, assigns} = analyze_list(args, tainted_vars, vars, assigns, [])
        do_block = maybe_block_to_rendered(do_block, tainted_vars, vars, assigns)
        to_safe({:live_component, meta, args ++ [[do: do_block]]}, true)

      _ ->
        to_safe(expr, true)
    end
  end

  defp to_live_struct({:for, _, [_ | _]} = expr, tainted_vars, vars, assigns) do
    with {:for, meta, [_ | _] = args} <- expr,
         {filters, [[do: {:__block__, _, block}]]} <- Enum.split(args, -1),
         {dynamic, [{:safe, static}]} <- Enum.split(block, -1) do
      {block, static, dynamic, fingerprint} =
        analyze_static_and_dynamic(static, dynamic, false, tainted_vars, vars, assigns)

      for = {:for, meta, filters ++ [[do: {:__block__, [], block ++ [dynamic]}]]}

      quote do
        %Phoenix.LiveView.Comprehension{
          static: unquote(static),
          dynamics: unquote(for),
          fingerprint: unquote(fingerprint)
        }
      end
    else
      _ -> to_safe(expr, true)
    end
  end

  defp to_live_struct({macro, meta, [_ | _] = args} = expr, tainted_vars, vars, assigns)
       when is_atom(macro) do
    if classify_taint(macro, args) == :live do
      {args, [opts]} = Enum.split(args, -1)
      {args, tainted_vars, vars, assigns} = analyze_list(args, tainted_vars, vars, assigns, [])

      opts =
        for {key, value} <- opts do
          {key, maybe_block_to_rendered(value, tainted_vars, vars, assigns)}
        end

      to_safe({macro, meta, args ++ [opts]}, true)
    else
      to_safe(expr, true)
    end
  end

  defp to_live_struct(expr, _tainted_vars, _vars, _assigns) do
    to_safe(expr, true)
  end

  defp maybe_block_to_rendered([{:->, _, _} | _] = blocks, tainted_vars, vars, assigns) do
    # First collect all vars across all assigns since cond/case may be linear
    {blocks, {tainted_vars, vars, assigns}} =
      Enum.map_reduce(blocks, {tainted_vars, vars, assigns}, fn
        {:->, meta, [args, block]}, {tainted_vars, vars, assigns} ->
          {args, tainted_vars, vars, assigns} =
            analyze_list(args, tainted_vars, vars, assigns, [])

          {{:->, meta, [args, block]}, {tainted_vars, vars, assigns}}
      end)

    # Now convert blocks
    for {:->, meta, [args, block]} <- blocks do
      {:->, meta, [args, maybe_block_to_rendered(block, tainted_vars, vars, assigns)]}
    end
  end

  defp maybe_block_to_rendered(block, tainted_vars, vars, assigns) do
    case to_rendered_struct(block, false, tainted_vars, vars, assigns) do
      {_fingerprint, rendered} -> {:__block__, [], rendered}
      :error -> block
    end
  end

  ## Emit conditional variables for dirty assigns tracking.

  defp maybe_pdict_fingerprint(ast, false, _counter), do: ast

  defp maybe_pdict_fingerprint(ast, true, counter) do
    quote do
      case prints do
        %{unquote(counter) => {_, _} = print} -> Process.put(unquote(@pdict_key), print)
        %{} -> :ok
      end

      unquote(ast)
    end
  end

  defp to_conditional_var(:all, var, live_struct) do
    quote do: unquote(var) = unquote(live_struct)
  end

  defp to_conditional_var([], var, live_struct) do
    quote do
      unquote(var) =
        case changed do
          %{} -> nil
          _ -> unquote(live_struct)
        end
    end
  end

  defp to_conditional_var(keys, var, live_struct) do
    quote do
      unquote(var) =
        case unquote(changed_assigns(keys)) do
          true -> unquote(live_struct)
          false -> nil
        end
    end
  end

  defp changed_assigns(assigns) do
    assigns
    |> Enum.map(fn assign ->
      quote do: unquote(__MODULE__).changed_assign?(changed, unquote(assign))
    end)
    |> Enum.reduce(&{:or, [], [&1, &2]})
  end

  ## Extracts binaries and variable from iodata

  defp bins_and_vars(acc),
    do: bins_and_vars(acc, [], [])

  defp bins_and_vars([bin1, bin2 | acc], bins, vars) when is_binary(bin1) and is_binary(bin2),
    do: bins_and_vars([bin1 <> bin2 | acc], bins, vars)

  defp bins_and_vars([bin, var | acc], bins, vars) when is_binary(bin) and is_tuple(var),
    do: bins_and_vars(acc, [bin | bins], [var | vars])

  defp bins_and_vars([var | acc], bins, vars) when is_tuple(var),
    do: bins_and_vars(acc, ["" | bins], [var | vars])

  defp bins_and_vars([bin], bins, vars) when is_binary(bin),
    do: {Enum.reverse([bin | bins]), Enum.reverse(vars)}

  defp bins_and_vars([], bins, vars),
    do: {Enum.reverse(["" | bins]), Enum.reverse(vars)}

  ## Assigns tracking

  # Here we compute if an expression should be always computed (:tainted),
  # never computed (no assigns) or some times computed based on assigns.
  #
  # If any assign is used, we store it in the assigns and use it to compute
  # if it should be changed or not.
  #
  # However, operations that change the lexical scope, such as imports and
  # defining variables, taint the analysis. Because variables can be set at
  # any moment in Elixir, via macros, without appearing on the left side of
  # `=` or in a clause, whenever we see a variable, we consider it as tainted,
  # regardless of its position.
  #
  # The tainting that happens from lexical scope is called weak-tainting,
  # because it is disabled under certain special forms. There is also
  # strong-tainting, which are always computed. Strong-tainting only happens
  # if the `assigns` variable is used.
  defp analyze_and_return_tainted_keys(ast, tainted_vars, vars, assigns) do
    {ast, tainted_vars, vars, assigns} = analyze(ast, tainted_vars, vars, assigns)
    {tainted_assigns?, assigns} = Map.pop(assigns, __MODULE__, false)
    keys = if tainted_vars or tainted_assigns?, do: :all, else: Map.keys(assigns)
    {ast, keys, vars}
  end

  # Non-expanded assign access
  defp analyze({:@, meta, [{name, _, context}]}, tainted_vars, vars, assigns)
       when is_atom(name) and is_atom(context) do
    assigns_var = Macro.var(:assigns, nil)

    expr =
      quote line: meta[:line] || 0 do
        unquote(__MODULE__).fetch_assign!(unquote(assigns_var), unquote(name))
      end

    {expr, tainted_vars, vars, Map.put(assigns, name, true)}
  end

  # Expanded assign access. The non-expanded form is handled on root,
  # then all further traversals happen on the expanded form
  defp analyze(
         {{:., _, [__MODULE__, :fetch_assign!]}, _, [{:assigns, _, nil}, name]} = expr,
         tainted_vars,
         vars,
         assigns
       )
       when is_atom(name) do
    {expr, tainted_vars, vars, Map.put(assigns, name, true)}
  end

  # Assigns is a strong-taint
  defp analyze({:assigns, _, nil} = expr, tainted_vars, vars, assigns) do
    {expr, tainted_vars, vars, taint(assigns)}
  end

  # Our own vars are ignored. They appear from nested do/end in EEx templates.
  defp analyze({_, _, __MODULE__} = expr, tainted_vars, vars, assigns) do
    {expr, tainted_vars, vars, assigns}
  end

  # Vars always taint
  defp analyze({name, _, context} = expr, tainted_vars, vars, assigns)
       when is_atom(name) and is_atom(context) do
    if tainted_vars == :restricted do
      {expr, Map.has_key?(vars, {name, context}) || :restricted, vars, assigns}
    else
      {expr, true, Map.put(vars, {name, context}, true), assigns}
    end
  end

  # Ignore binary modifiers
  defp analyze({:"::", meta, [left, right]}, tainted_vars, vars, assigns) do
    {left, tainted_vars, vars, assigns} = analyze(left, tainted_vars, vars, assigns)
    {{:"::", meta, [left, right]}, tainted_vars, vars, assigns}
  end

  # Classify calls
  defp analyze({left, meta, args} = expr, tainted_vars, vars, assigns) do
    case classify_taint(left, args) do
      :always ->
        tainted_vars = if tainted_vars == :restricted, do: :restricted, else: true
        {expr, tainted_vars, vars, assigns}

      :never ->
        {args, tainted_vars, vars, assigns} =
          analyze_with_restricted_tainted_vars(args, tainted_vars, vars, assigns)

        {{left, meta, args}, tainted_vars, vars, assigns}

      :live ->
        {args, [opts]} = Enum.split(args, -1)
        {args, tainted_vars, vars, assigns} = analyze_list(args, tainted_vars, vars, assigns, [])

        {opts, tainted_vars, vars, assigns} =
          analyze_with_restricted_tainted_vars(opts, tainted_vars, vars, assigns)

        {{left, meta, args ++ [opts]}, tainted_vars, vars, assigns}

      :none ->
        {left, tainted_vars, vars, assigns} = analyze(left, tainted_vars, vars, assigns)
        {args, tainted_vars, vars, assigns} = analyze_list(args, tainted_vars, vars, assigns, [])
        {{left, meta, args}, tainted_vars, vars, assigns}
    end
  end

  defp analyze({left, right}, tainted_vars, vars, assigns) do
    {left, tainted_vars, vars, assigns} = analyze(left, tainted_vars, vars, assigns)
    {right, tainted_vars, vars, assigns} = analyze(right, tainted_vars, vars, assigns)
    {{left, right}, tainted_vars, vars, assigns}
  end

  defp analyze([_ | _] = list, tainted_vars, vars, assigns) do
    analyze_list(list, tainted_vars, vars, assigns, [])
  end

  defp analyze(other, tainted_vars, vars, assigns) do
    {other, tainted_vars, vars, assigns}
  end

  defp analyze_list([head | tail], tainted_vars, vars, assigns, acc) do
    {head, tainted_vars, vars, assigns} = analyze(head, tainted_vars, vars, assigns)
    analyze_list(tail, tainted_vars, vars, assigns, [head | acc])
  end

  defp analyze_list([], tainted_vars, vars, assigns, acc) do
    {Enum.reverse(acc), tainted_vars, vars, assigns}
  end

  # tainted_vars is mostly a boolean. False means variables are not
  # tainted, true means they are. Seeing a variable at any moment
  # taints it.
  #
  # However, for case/cond/with/fn/try, the variable is only tainted
  # if it came from outside of the case/cond/with/fn/try. So for those
  # constructs we set the mode to restricted and stop collecting vars.
  defp analyze_with_restricted_tainted_vars(ast, tainted_vars, vars, assigns) do
    {analyzed, tainted_vars, _vars, assigns} =
      analyze(ast, tainted_vars || :restricted, vars, assigns)

    {analyzed, tainted_vars == true, vars, assigns}
  end

  defp taint(assigns) do
    Map.put(assigns, __MODULE__, true)
  end

  ## Callbacks

  defp static_fingerprint(static) do
    # We compute the term to binary instead of passing all binaries
    # because we need to take into account the positions of dynamics.
    <<fingerprint::8*16>> =
      static
      |> :erlang.term_to_binary()
      |> :erlang.md5()

    fingerprint
  end

  @doc false
  defmacro to_safe(ast) do
    to_safe(ast, false)
  end

  defp to_safe(ast, false) do
    to_safe(ast, line_from_expr(ast), [])
  end

  defp to_safe(ast, true) do
    line = line_from_expr(ast)

    extra_clauses =
      quote generated: true do
        %{__struct__: Phoenix.LiveView.Rendered} = other -> other
        %{__struct__: Phoenix.LiveView.Component} = other -> other
        %{__struct__: Phoenix.LiveView.Comprehension} = other -> other
      end

    to_safe(ast, line, extra_clauses)
  end

  defp line_from_expr({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from_expr(_), do: nil

  # We can do the work at compile time
  defp to_safe(literal, _line, _extra_clauses)
       when is_binary(literal) or is_atom(literal) or is_number(literal) do
    Phoenix.HTML.Safe.to_iodata(literal)
  end

  # We can do the work at runtime
  defp to_safe(literal, line, _extra_clauses) when is_list(literal) do
    quote line: line, do: Phoenix.HTML.Safe.List.to_iodata(unquote(literal))
  end

  defp to_safe(expr, line, extra_clauses) do
    # Keep stacktraces for protocol dispatch and coverage
    safe_return = quote line: line, do: data
    bin_return = quote line: line, do: Plug.HTML.html_escape_to_iodata(bin)
    other_return = quote line: line, do: Phoenix.HTML.Safe.to_iodata(other)

    # However ignore them for the generated clauses to avoid warnings
    clauses =
      quote generated: true do
        {:safe, data} -> unquote(safe_return)
        bin when is_binary(bin) -> unquote(bin_return)
        other -> unquote(other_return)
      end

    quote generated: true do
      case unquote(expr), do: unquote(extra_clauses ++ clauses)
    end
  end

  @doc false
  def changed_assign?(nil, _name) do
    true
  end

  def changed_assign?(changed, name) do
    case changed do
      %{^name => _} -> true
      %{} -> false
    end
  end

  @doc false
  def fetch_assign!(assigns, key) do
    case assigns do
      %{^key => val} ->
        val

      %{} ->
        raise ArgumentError, """
        assign @#{key} not available in eex template.

        Please make sure all proper assigns have been set. If this
        is a child template, ensure assigns are given explicitly by
        the parent template as they are not automatically forwarded.

        Available assigns: #{inspect(Enum.map(assigns, &elem(&1, 0)))}
        """
    end
  end

  defp classify_taint(:case, [_, _]), do: :live
  defp classify_taint(:if, [_, _]), do: :live
  defp classify_taint(:cond, [_]), do: :live
  defp classify_taint(:try, [_]), do: :live
  defp classify_taint(:receive, [_]), do: :live

  defp classify_taint(:alias, [_]), do: :always
  defp classify_taint(:import, [_]), do: :always
  defp classify_taint(:require, [_]), do: :always
  defp classify_taint(:alias, [_, _]), do: :always
  defp classify_taint(:import, [_, _]), do: :always
  defp classify_taint(:require, [_, _]), do: :always

  defp classify_taint(:&, [_]), do: :never
  defp classify_taint(:with, _), do: :never
  defp classify_taint(:for, _), do: :never
  defp classify_taint(:fn, _), do: :never

  defp classify_taint(_, _), do: :none
end
