defmodule Svmm.StaleStartup do
  @moduledoc """
  Recovers when EKV refuses to start because its on-disk data is stale.

  EKV records when a node was last active. If that is older than `tombstone_ttl`
  (7 days by default), other members may already have purged the records of keys
  deleted in the meantime, so trusting the old data could bring deleted keys back.
  EKV then fails startup with `{:stale_db, info}`. What to do depends on the node:

  | Node | Decision |
  |---|---|
  | replica | **wipe** its shard files and resync from the primary. A replica never holds data the primary lacks. |
  | primary, `CLUSTER_SIZE=1` | **trust** its data. It is the only voting copy, so nobody else can have purged anything. |
  | primary, `CLUSTER_SIZE>1` | the **operator decides**: `EKV_STALE_STARTUP=trust` or `=wipe`, otherwise an interactive prompt when started from a terminal, otherwise refuse to start with instructions. |

  Every recovery prints a notice on stderr for whoever started the node and logs
  one line with the full details (path, age, threshold, role, cluster size,
  decision, deleted files).
  """
  require Logger

  @type info :: %{
          required(:path) => String.t(),
          required(:reason) => atom(),
          optional(:age_ms) => non_neg_integer() | nil,
          optional(:threshold_ms) => non_neg_integer()
        }
  @type decision :: :trust | :wipe | :ask
  @type start_fun :: (keyword() -> Supervisor.on_start())

  @prompt_timeout :timer.minutes(5)
  @day_ms :timer.hours(24)

  @doc """
  Calls `start_fun.([])`. If that fails because EKV found stale data, applies the
  decision for this node and calls it once more: with `allow_stale_startup: true`
  to trust the data, or with no extra options after wiping it.

  `start_fun` receives extra EKV options to merge into the EKV child spec.

  Options (for tests): `:interactive?` and `:gets`, see `resolve/3`.
  """
  @spec start(start_fun(), map(), keyword()) :: Supervisor.on_start() | {:error, term()}
  def start(start_fun, config, opts \\ []) do
    with {:error, reason} <- attempt(start_fun, []),
         %{} = info <- find(reason) || {:error, reason} do
      case resolve(config, info, opts) do
        :trust ->
          attempt(start_fun, allow_stale_startup: true)

        :wipe ->
          deleted = wipe!(Svmm.Config.ekv_data_dir(config))
          report_wipe(deleted)
          attempt(start_fun, [])

        {:abort, message} ->
          {:error, {:stale_db_refused, message}}
      end
    end
  end

  # A supervisor that fails in init also sends an exit signal to the caller it is
  # linked to. Trap it for the duration of the call so a failed first attempt
  # does not kill us before we can recover, then drop the stray EXIT message.
  defp attempt(start_fun, overrides) do
    previous = Process.flag(:trap_exit, true)

    try do
      case start_fun.(overrides) do
        {:error, _} = error ->
          receive do
            {:EXIT, _pid, _reason} -> :ok
          after
            0 -> :ok
          end

          error

        other ->
          other
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  @doc "Finds EKV's `{:stale_db, info}` anywhere inside a start error."
  @spec find(term()) :: info() | nil
  def find({:stale_db, %{path: _} = info}), do: info
  def find(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> find()
  def find(list) when is_list(list), do: Enum.find_value(list, &find/1)
  def find(_), do: nil

  @doc "The decision for this node, before any prompting."
  @spec decide(map()) :: decision()
  def decide(config) do
    case {Svmm.Config.node_role(config), Svmm.Config.cluster_size(config)} do
      {:replica, _} -> :wipe
      {:primary, size} when size <= 1 -> :trust
      {:primary, _} -> operator_override(config)
    end
  end

  @doc """
  Decides, tells the user and logs it. Returns `:trust`, `:wipe` or
  `{:abort, message}`.

  Options:
    * `:interactive?` - whether a person can answer a prompt. Defaults to
      whether stdin is a terminal.
    * `:gets` - function used to read the answer (defaults to `IO.gets/1`).
  """
  @spec resolve(map(), info(), keyword()) :: :trust | :wipe | {:abort, String.t()}
  def resolve(config, info, opts \\ []) do
    decision =
      case decide(config) do
        :ask -> ask(config, info, opts)
        other -> other
      end

    report(decision, config, info)
    decision
  end

  @doc """
  Deletes EKV's shard files (`shard_N.db`, `-wal`, `-shm`) in `data_dir`.
  Nothing else in the directory is touched. Returns the deleted paths.
  """
  @spec wipe!(String.t()) :: [String.t()]
  def wipe!(data_dir) do
    case File.ls(data_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(~r/\Ashard_\d+\.db(-wal|-shm)?\z/, &1))
        |> Enum.map(&Path.join(data_dir, &1))
        |> Enum.map(fn path ->
          File.rm!(path)
          path
        end)

      {:error, _} ->
        []
    end
  end

  # --- deciding -------------------------------------------------------------

  defp operator_override(config) do
    case config["EKV_STALE_STARTUP"] do
      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "trust" -> :trust
          "wipe" -> :wipe
          _ -> :ask
        end

      _ ->
        :ask
    end
  end

  defp ask(config, info, opts) do
    if Keyword.get_lazy(opts, :interactive?, &interactive?/0) do
      gets = Keyword.get(opts, :gets, &IO.gets/1)
      notice(:ask, config, info)
      prompt(gets)
    else
      {:abort, abort_message(config, info)}
    end
  end

  defp interactive? do
    Keyword.get(:io.getopts(:standard_io), :stdin, false) == true
  rescue
    _ -> false
  end

  defp prompt(gets) do
    task =
      Task.async(fn ->
        gets.("Type t to trust the data, w to wipe it, anything else to abort: ")
      end)

    answer =
      case Task.yield(task, @prompt_timeout) || Task.shutdown(task) do
        {:ok, value} when is_binary(value) -> value |> String.trim() |> String.downcase()
        _ -> ""
      end

    case answer do
      a when a in ["t", "trust"] -> :trust
      a when a in ["w", "wipe"] -> :wipe
      _ -> {:abort, "aborted by the operator at the stale-data prompt"}
    end
  end

  # --- telling the user and the logs ------------------------------------------

  defp report(decision, config, info) do
    unless decision == :ask, do: notice(decision, config, info)

    name =
      case decision do
        {:abort, _} -> "abort"
        other -> Atom.to_string(other)
      end

    log =
      "EKV stale data at startup: decision=#{name} " <>
        "role=#{Svmm.Config.node_role(config)} cluster_size=#{Svmm.Config.cluster_size(config)} " <>
        "path=#{info.path} reason=#{info.reason} age=#{age(info)} threshold=#{threshold(info)}"

    case decision do
      {:abort, _} -> Logger.error(log)
      _ -> Logger.warning(log)
    end
  end

  defp report_wipe(deleted) do
    Logger.warning(
      "EKV stale data: deleted #{length(deleted)} file(s): #{Enum.join(deleted, ", ")}"
    )

    banner(["Deleted #{length(deleted)} file(s):" | Enum.map(deleted, &"  #{&1}")])
  end

  defp notice(decision, config, info) do
    header = [
      "EKV data at #{Path.dirname(info.path)} is #{age(info)} old (limit #{threshold(info)}).",
      "Data that old may be missing deletions made by other cluster members."
    ]

    body =
      case decision do
        :trust ->
          [
            "This is the only voting member (CLUSTER_SIZE=#{Svmm.Config.cluster_size(config)}), so its",
            "data is the latest copy there is. Starting with the data as it is."
          ]

        :wipe ->
          case Svmm.Config.node_role(config) do
            :replica ->
              ["This is a replica: deleting its local copy and resyncing from the primary."]

            :primary ->
              [
                "Operator chose to wipe: deleting local data and resyncing from the other members."
              ]
          end

        :ask ->
          [
            "This primary has CLUSTER_SIZE=#{Svmm.Config.cluster_size(config)}: other members may",
            "hold newer data. Choose:",
            "  t (trust) keep local data; keys deleted elsewhere may come back",
            "  w (wipe)  delete local data and resync from the other members"
          ]

        {:abort, message} ->
          String.split(message, "\n", trim: true)
      end

    banner(header ++ [""] ++ body)
  end

  defp abort_message(config, info) do
    """
    Refusing to start: EKV data at #{Path.dirname(info.path)} is #{age(info)} old and this primary \
    has CLUSTER_SIZE=#{Svmm.Config.cluster_size(config)}, so other members may hold newer data.
    Decide, set ONE of these for a single start, then remove it:
      EKV_STALE_STARTUP=wipe   delete local data and resync from the other members
      EKV_STALE_STARTUP=trust  keep local data; keys deleted elsewhere may come back
    """
  end

  defp banner(lines) do
    rule = String.duplicate("=", 72)
    IO.puts(:stderr, Enum.join([rule, "SVMM startup: stale EKV data" | lines] ++ [rule], "\n"))
  end

  defp age(%{age_ms: ms}) when is_integer(ms), do: human(ms)
  defp age(_), do: "unknown age (no last-active timestamp)"

  defp threshold(%{threshold_ms: ms}) when is_integer(ms), do: human(ms)
  defp threshold(_), do: "unknown"

  # Rounded, not truncated: EKV's threshold is tombstone_ttl minus gc_interval
  # (7 days - 5 min), which must read as "7 days", not "6 days".
  defp human(ms) when ms >= @day_ms, do: plural(round(ms / @day_ms), "day")
  defp human(ms) when ms >= 3_600_000, do: plural(round(ms / 3_600_000), "hour")
  defp human(ms) when ms >= 1000, do: plural(round(ms / 1000), "second")
  defp human(ms), do: "#{ms} ms"

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"
end
