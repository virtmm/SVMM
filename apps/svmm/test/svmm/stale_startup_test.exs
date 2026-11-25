defmodule Svmm.StaleStartupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Svmm.StaleStartup

  @info %{
    reason: :stale_last_active_at,
    path: "/data/ekv_store/shard_0.db",
    age_ms: 13_097_849_525,
    threshold_ms: 604_500_000
  }

  defp error_with(info) do
    {:shutdown,
     {:failed_to_start_child, {EKV, :svmm_cluster},
      {:shutdown,
       {:failed_to_start_child, EKV.Replica.Supervisor,
        {:shutdown, {:failed_to_start_child, {EKV.Replica, 0}, {:stale_db, info}}}}}}}
  end

  defp config(role, size, extra \\ %{}) do
    Map.merge(%{"NODE_ROLE" => role, "CLUSTER_SIZE" => to_string(size)}, extra)
  end

  describe "find/1" do
    test "finds the stale_db info nested in a supervisor start error" do
      assert StaleStartup.find(error_with(@info)) == @info
    end

    test "returns nil for any other error" do
      assert StaleStartup.find({:shutdown, {:failed_to_start_child, Foo, :boom}}) == nil
      assert StaleStartup.find(:boom) == nil
    end
  end

  describe "decide/1" do
    test "a replica always wipes, whatever the override" do
      assert StaleStartup.decide(config("replica", 1)) == :wipe
      assert StaleStartup.decide(config("replica", 3, %{"EKV_STALE_STARTUP" => "trust"})) == :wipe
    end

    test "a single-member primary trusts its data (it is the only copy)" do
      assert StaleStartup.decide(config("primary", 1)) == :trust
    end

    test "a multi-member primary asks, unless the operator already decided" do
      assert StaleStartup.decide(config("primary", 3)) == :ask

      assert StaleStartup.decide(config("primary", 3, %{"EKV_STALE_STARTUP" => "trust"})) ==
               :trust

      assert StaleStartup.decide(config("primary", 3, %{"EKV_STALE_STARTUP" => " WIPE "})) ==
               :wipe

      assert StaleStartup.decide(config("primary", 3, %{"EKV_STALE_STARTUP" => "maybe"})) == :ask
    end
  end

  describe "resolve/3 for a multi-member primary" do
    test "without a terminal it aborts with instructions" do
      log =
        capture_log(fn ->
          stderr =
            capture_io(:stderr, fn ->
              assert {:abort, msg} =
                       StaleStartup.resolve(config("primary", 3), @info, interactive?: false)

              assert msg =~ "EKV_STALE_STARTUP=wipe"
              assert msg =~ "EKV_STALE_STARTUP=trust"
            end)

          assert stderr =~ "152 days old (limit 7 days)"
        end)

      assert log =~ "decision=abort"
    end

    test "with a terminal it asks and follows the answer" do
      for {answer, expected} <- [{"t\n", :trust}, {"w\n", :wipe}, {"a\n", :abort}, {"", :abort}] do
        capture_log(fn ->
          capture_io(:stderr, fn ->
            result =
              StaleStartup.resolve(config("primary", 3), @info,
                interactive?: true,
                gets: fn _prompt -> if answer == "", do: :eof, else: answer end
              )

            assert result == expected or match?({^expected, _}, result)
          end)
        end)
      end
    end
  end

  describe "wipe!/1" do
    @tag :tmp_dir
    test "deletes only EKV shard files", %{tmp_dir: dir} do
      shard_files = ~w(shard_0.db shard_0.db-wal shard_0.db-shm shard_1.db)
      keep = ~w(current notes.txt)
      for f <- shard_files ++ keep, do: File.write!(Path.join(dir, f), "x")

      deleted = StaleStartup.wipe!(dir)

      assert Enum.sort(Enum.map(deleted, &Path.basename/1)) == Enum.sort(shard_files)
      assert Enum.sort(File.ls!(dir)) == Enum.sort(keep)
    end

    @tag :tmp_dir
    test "is a no-op on a missing directory", %{tmp_dir: dir} do
      assert StaleStartup.wipe!(Path.join(dir, "missing")) == []
    end
  end

  # End to end against a real EKV that refuses a stale database.
  describe "start/3 with a real stale EKV" do
    @tag :tmp_dir
    test "a single-member primary starts by trusting its data", %{tmp_dir: dir} do
      start = stale_ekv(dir)

      log =
        capture_log(fn ->
          capture_io(:stderr, fn ->
            assert {:ok, pid} = StaleStartup.start(start, config("primary", 1, ekv_dir(dir)))
            Supervisor.stop(pid)
          end)
        end)

      assert log =~ "decision=trust"
      assert File.exists?(Path.join(dir, "shard_0.db"))
    end

    @tag :tmp_dir
    test "a replica starts by wiping its data", %{tmp_dir: dir} do
      start = stale_ekv(dir)

      log =
        capture_log(fn ->
          stderr =
            capture_io(:stderr, fn ->
              assert {:ok, pid} = StaleStartup.start(start, config("replica", 1, ekv_dir(dir)))
              Supervisor.stop(pid)
            end)

          assert stderr =~ ~r/deleted/i
        end)

      assert log =~ "decision=wipe"
      assert log =~ "shard_0.db"
    end

    @tag :tmp_dir
    test "a multi-member primary without a terminal refuses to start", %{tmp_dir: dir} do
      start = stale_ekv(dir)

      capture_log(fn ->
        capture_io(:stderr, fn ->
          assert {:error, {:stale_db_refused, _msg}} =
                   StaleStartup.start(start, config("primary", 3, ekv_dir(dir)),
                     interactive?: false
                   )
        end)
      end)
    end

    test "other start errors are returned untouched" do
      assert StaleStartup.start(fn _ -> {:error, :boom} end, config("primary", 1)) ==
               {:error, :boom}
    end
  end

  defp ekv_dir(dir), do: %{"EKV_DATA_DIR" => dir}

  # Writes a real EKV database in `dir`, then returns a start function whose
  # tombstone_ttl is so short that the database is already stale.
  defp stale_ekv(dir) do
    name = :"stale_ekv_#{System.unique_integer([:positive])}"
    base = [name: name, data_dir: dir, cluster_size: 1, shards: 1]

    {:ok, pid} = EKV.start_link(base)
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Supervisor.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    fn overrides ->
      EKV.start_link(base ++ [tombstone_ttl: 2, gc_interval: 1] ++ overrides)
    end
  end
end
