defmodule Svmm.Config do
  @moduledoc """
  Reads configuration from a dotenv-style svmm.conf file.
  The configuration file allows for you to provide configuration in different ways, for different use cases.

  Searches in order: `./svmm.conf`, `/etc/svmm.conf`.
  Environment varilables take precedence over the config file, and application environment takes precedence over both.

  Falls back to environment variables if no file is found.

  The same file can be used as a systemd EnvironmentFile.
  """
  require Logger

  @default_shards 2
  @default_cluster_size 1

  @keys [
    {"NODE_NAME", :node_name},
    {"ERLANG_COOKIE", :erlang_cookie},
    {"NODE_ROLE", :node_role},
    {"EKV_DATA_DIR", :ekv_data_dir},
    {"DNS_CLUSTER_QUERY", :dns_cluster_query},
    {"CLUSTER_SIZE", :cluster_size},
    {"EKV_SHARDS", :ekv_shards}
  ]

  @spec load() :: %{String.t() => String.t()}
  def load do
    file_config =
      case find_config_file() do
        {:ok, path} ->
          Logger.info("Loading config from #{path}")
          parse_file(path)

        :none ->
          Logger.debug(
            "No svmm.conf found at #{inspect(config_paths())}, using environment variables"
          )

          %{}
      end

    # Precedence (highest first), matching the moduledoc: application
    # environment, then OS environment variables, then the config file.
    Map.new(@keys, fn {env_key, app_key} ->
      value =
        app_env_as_string(app_key) ||
          System.get_env(env_key) ||
          Map.get(file_config, env_key)

      {env_key, value}
    end)
  end

  defp app_env_as_string(key) do
    case Application.get_env(:svmm, key) do
      nil -> nil
      val when is_binary(val) -> val
      val when is_atom(val) -> Atom.to_string(val)
      val -> to_string(val)
    end
  end

  @spec node_role(%{String.t() => String.t() | nil}) :: :primary | :replica
  def node_role(config) do
    case config["NODE_ROLE"] do
      role when is_binary(role) ->
        if String.downcase(String.trim(role)) == "replica", do: :replica, else: :primary

      _ ->
        :primary
    end
  end

  @spec node_name(%{String.t() => String.t() | nil}) :: atom() | nil
  def node_name(config) do
    case config["NODE_NAME"] do
      nil -> nil
      "" -> nil
      name -> String.to_atom(name)
    end
  end

  @spec cookie(%{String.t() => String.t() | nil}) :: atom() | nil
  def cookie(config) do
    case config["ERLANG_COOKIE"] do
      nil -> nil
      "" -> nil
      cookie -> String.to_atom(cookie)
    end
  end

  @spec primary_address(%{String.t() => String.t() | nil}) :: String.t() | nil
  def primary_address(config), do: config["DNS_CLUSTER_QUERY"]

  @spec ekv_data_dir(%{String.t() => String.t() | nil}) :: String.t()
  def ekv_data_dir(config) do
    config["EKV_DATA_DIR"] || Path.expand("data/ekv_store")
  end

  @spec cluster_size(%{String.t() => String.t() | nil}) :: integer()
  def cluster_size(config) do
    with value when is_binary(value) <- config["CLUSTER_SIZE"],
         {int_value, ""} <- Integer.parse(value) do
      int_value
    else
      value when is_integer(value) -> value
      _ -> @default_cluster_size
    end
  end

  @spec ekv_shards(%{String.t() => String.t() | nil}) :: integer()
  def ekv_shards(config) do
    with value when is_binary(value) <- config["EKV_SHARDS"],
         {int_value, ""} <- Integer.parse(value) do
      int_value
    else
      value when is_integer(value) -> value
      _ -> @default_shards
    end
  end

  @doc false
  defp config_paths do
    [Path.expand("svmm.conf"), "/etc/svmm.conf"]
  end

  defp find_config_file do
    Enum.find_value(config_paths(), :none, fn path ->
      if File.exists?(path), do: {:ok, path}
    end)
  end

  @doc false
  @spec parse_file(String.t()) :: %{String.t() => String.t()}
  def parse_file(path) do
    path
    |> File.read!()
    |> parse_string()
  end

  @doc false
  @spec parse_string(String.t()) :: %{String.t() => String.t()}
  def parse_string(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      case line do
        "" -> acc
        "#" <> _ -> acc
        _ -> parse_line(line, acc)
      end
    end)
  end

  @doc false
  defp parse_line(line, acc) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        Map.put(acc, String.trim(key), String.trim(value))

      _ ->
        acc
    end
  end
end
