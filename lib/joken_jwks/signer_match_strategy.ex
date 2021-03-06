defmodule JokenJwks.SignerMatchStrategy do
  @moduledoc """
  A strategy behaviour for using with `JokenJwks`.

  JokenJwks will call this for every token with a kid. It is the strategy
  responsability to handle cache and matching of the kid with its signers
  cache.

  See `JokenJwks.DefaultStrategy` for an implementation.
  """

  @callback match_signer_for_kid(kid :: binary(), hook_options :: any()) ::
              {:ok, Joken.Signer.t()} | {:error, reason :: atom()}
end
