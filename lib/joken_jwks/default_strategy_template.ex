defmodule JokenJwks.DefaultStrategyTemplate do
  @moduledoc """
  A `JokenJwks.SignerMatchStrategy` template that has a window of time for refreshing its 
  cache. This is a template and not a concrete implementation. You should `use` this module
  in order to use the default strategy.

  This implementation is a task that should be supervised. It loops on a time window checking 
  whether it should refetch keys or not.

  Everytime a bad kid is received it writes to an ets table a counter to 1. When the task
  loops, it polls for the counter value. If it is more than zero it starts refecthing the 
  cache. Upon successful fetching, it zeros the counter once again. This way we avoid 
  overloading the JWKS server.

  It will try to fetch signers when supervision starts it. This can be a sync or async operation
  depending on the value of `first_fetch_sync`. It defaults to `false`. 

  ## Usage

  This strategy must be under your apps' supervision tree. It must be explicetely used under a
  module so that you can have more than one JWKS source. 

  When using this strategy, there is an `init_opts/1` callback that can be overriden. This is called
  upon supervision start. It should return a keyword list with all the options. This follows the
  standard practice of allowing a callback for using runtime configuration. It can override all
  other options as this has higher preference.

  ## Configuration

  Other than the `init_opts/1` callback you can pass options through `Mix.Config` and when starting 
  the supervisor. The order of preference in least significant order is:
    - Per environment `Mix.Config`
    - Supervisor child options
    - `init_opts/1` callback

  The only mandatory option is `jwks_url` (`binary()`) that is, usually, a runtime parameter like a system 
  environment variable. It is recommended to use the `init_opts/1` callback. 

  Other options are:

    - `time_interval` (`integer()` - default 60_000 (1 minute)): time interval for polling if it is needed to 
    refetch the keys;
    - `log_level` (`:none | :debug | :info | :warn | :error` - default `:debug`): the level of log to use for 
    events in the strategy like HTTP errors and so on. It is advised not to turn off logging in production;
    - `should_start` (`boolean()` - default true): whether to start the supervised polling task. For tests, this 
    should be false;
    - `first_fetch_sync` (`boolean()` - default false): whether to fetch the first time synchrounously or async.

  ### Example usage:

      defmodule MyStrategy do
        use JokenJwks.DefaultStrategy

        def init(opts) do
          url = # fetch url ...
          Keyword.merge(opts, jwks_url: url)
        end
      end

      defmodule JokenExample.Application do
        @doc false
        def start(_type, _args) do
          import Supervisor.Spec, warn: false
      
          children = [
            {MyStrategy, time_interval: 2_000}
          ]

          opts = [strategy: :one_for_one]
          Supervisor.start_link(children, opts)
        end
      end

  Then on your token configuration module:

      defmodule MyToken do
        use Joken.Config

        add_hook(JokenJwks, strategy: MyStrategy)
        # rest of your token config
      end
  """

  defmacro __using__(_opts) do
    # credo:disable-for-next-line
    quote do
      use Task, restart: :transient

      require Logger

      alias __MODULE__.EtsCache
      alias Joken.Signer
      alias JokenJwks.{HttpFetcher, SignerMatchStrategy}

      @behaviour SignerMatchStrategy

      defmodule EtsCache do
        @moduledoc "Simple ETS counter based state machine"

        @doc "Starts ETS cache"
        def new do
          :ets.new(__MODULE__, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ets.insert(__MODULE__, {:counter, 0})
        end

        @doc "Returns 0 - no need to fetch signers or 1 - need to fetch"
        def check_state do
          :ets.lookup_element(__MODULE__, :counter, 2)
        end

        @doc "Sets the cache status"
        def set_status(:refresh) do
          :ets.update_counter(__MODULE__, :counter, {2, 1, 1, 1}, {:counter, 0})
        end

        def set_status(:ok) do
          :ets.update_counter(__MODULE__, :counter, {2, -1, 1, 0}, {:counter, 0})
        end

        @doc "Loads fetched signers"
        def get_signers do
          :ets.lookup(__MODULE__, :signers)
        end

        @doc "Puts fetched signers"
        def put_signers(signers) do
          :ets.insert(__MODULE__, {:signers, signers})
        end
      end

      @doc "Callback for initializing options upon strategy startup"
      @spec init_opts(opts :: Keyword.t()) :: Keyword.t()
      def init_opts(opts), do: opts

      defoverridable init_opts: 1

      @doc false
      def start_link(opts) do
        opts =
          Application.get_env(:joken_jwks, __MODULE__, [])
          |> Keyword.merge(opts)
          |> init_opts()

        start? = if is_nil(opts[:should_start]), do: true, else: opts[:should_start]

        first_fetch_sync =
          if is_nil(opts[:first_fetch_sync]), do: false, else: opts[:first_fetch_sync]

        time_interval = opts[:time_interval] || 60 * 1_000
        log_level = opts[:log_level] || :debug
        url = opts[:jwks_url] || raise "No url set for fetching JWKS!"
        EtsCache.new()

        do_init(start?, first_fetch_sync, time_interval, log_level, url)
      end

      defp do_init(start?, first_fetch_sync, time_interval, log_level, url) do
        cond do
          start? and first_fetch_sync ->
            fetch_signers(url, log_level)
            Task.start_link(__MODULE__, :poll, [time_interval, log_level, url])

          start? ->
            start_fetch_signers(url, log_level)
            Task.start_link(__MODULE__, :poll, [time_interval, log_level, url])

          true ->
            {:ok, spawn_link(fn -> "Normal shutdown" end)}
        end
      end

      @impl SignerMatchStrategy
      def match_signer_for_kid(kid, _opts) do
        with {:cache, [{:signers, signers}]} <- {:cache, EtsCache.get_signers()},
             {:signer, signer} when not is_nil(signer) <- {:signer, signers[kid]} do
          {:ok, signer}
        else
          {:signer, nil} ->
            EtsCache.set_status(:refresh)
            {:error, :kid_does_not_match}

          {:cache, []} ->
            {:error, :no_signers_fetched}

          err ->
            err
        end
      end

      @doc false
      def poll(time_interval, log_level, url) when is_integer(time_interval) do
        receive do
        after
          time_interval ->
            check_fetch(url, log_level)
            poll(time_interval, log_level, url)
        end
      end

      defp check_fetch(url, log_level) do
        case EtsCache.check_state() do
          # no need to re-fetch
          0 ->
            JokenJwks.log(:debug, log_level, "Re-fetching cache is not needed.")
            :ok

          # start re-fetching
          _counter ->
            JokenJwks.log(:debug, log_level, "Re-fetching cache is needed and will start.")
            start_fetch_signers(url, log_level)
        end
      end

      defp start_fetch_signers(url, log_level) do
        Task.start(fn -> fetch_signers(url, log_level) end)
      end

      @doc "Fetch signers with `JokenJwks.HttpFetcher`"
      def fetch_signers(url, log_level) do
        with {:ok, keys} <- HttpFetcher.fetch_signers(url, log_level),
             {:ok, signers} <- validate_and_parse_keys(keys, log_level) do
          JokenJwks.log(:debug, log_level, "Fetched signers. #{inspect(signers)}")
          EtsCache.put_signers(signers)
          EtsCache.set_status(:ok)
        else
          {:error, _reason} = err ->
            JokenJwks.log(:error, log_level, "Failed to fetch signers. Reason: #{inspect(err)}")
            EtsCache.set_status(:refresh)

          err ->
            JokenJwks.log(
              :error,
              log_level,
              "Unexpected error while fetching signers. Reason: #{inspect(err)}"
            )

            EtsCache.set_status(:refresh)
        end
      end

      defp validate_and_parse_keys(keys, log_level) when is_list(keys) do
        Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
          with {:ok, signer} <- parse_signer(key, log_level) do
            {:cont, {:ok, Map.put(acc, key["kid"], signer)}}
          else
            e -> {:halt, e}
          end
        end)
      end

      defp parse_signer(key, log_level) do
        with {:kid, kid} when is_binary(kid) <- {:kid, key["kid"]},
             {:alg, alg} when is_binary(alg) <- {:alg, key["alg"]},
             {:ok, _signer} = res <- {:ok, Signer.create(alg, key)} do
          res
        else
          {:kid, _} -> {:error, :kid_not_binary}
          {:alg, _} -> {:error, :algorithm_not_binary}
        end
      rescue
        e ->
          JokenJwks.log(:error, log_level, """
          Error while parsing a key entry fetched from the network.

          This should be investigated by a human.

          Key: #{inspect(key)}

          Error: #{inspect(e)}
          """)

          {:error, :invalid_key_params}
      end
    end
  end
end