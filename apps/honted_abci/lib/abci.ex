defmodule HonteD.ABCI do
  @moduledoc """
  Entrypoint for all calls from Tendermint targeting the ABCI - abstract blockchain interface

  This manages the `honted` ABCI app's state.
  ABCI calls originate from :abci_server (Erlang)
  """
  require Logger
  use GenServer
  import HonteD.ABCI.Records

  alias HonteD.ABCI.EthereumContractState, as: EthereumContractState
  alias HonteD.ABCI.State, as: State
  alias HonteD.Transaction

  @doc """
  Tracks state which is controlled by consensus and also tracks local (mempool related, transient) state.
  Local state is being overwritten by consensus state on every commit.
  """
  defstruct [consensus_state: State.initial(),
             local_state: State.initial(),
             contract_state: EthereumContractState.initial()
            ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  def handle_request(request) do
    GenServer.call(__MODULE__, request)
  end

  def init(:ok) do
    {:ok, %__MODULE__{}}
  end

  def handle_call(request_info(version: _), _from, abci_app) do
    reply = response_info(last_block_height: 0)
    {:reply, reply, abci_app}
  end

  def handle_call(request_end_block(height: _height), _from, abci_app) do
    {:reply, response_end_block(diffs: []), abci_app}
  end

  def handle_call(request_begin_block(header: header(height: height)), _from, abci_app) do
    HonteD.ABCI.Events.notify(abci_app.consensus_state, %HonteD.API.Events.NewBlock{height: height})
    {:reply, response_begin_block(), abci_app}
  end

  def handle_call(request_commit(), _from, abci_app) do
    hash = (abci_app.consensus_state |> State.hash |> to_charlist)
    reply = response_commit(code: code(:ok), data: hash, log: 'commit log: yo!')
    {:reply, reply, %{abci_app | local_state: abci_app.consensus_state}}
  end

  def handle_call(request_check_tx(tx: tx), _from, abci_app) do
    with {:ok, decoded} <- HonteD.TxCodec.decode(tx),
         {:ok, new_local_state} <- handle_tx(abci_app, decoded, &(&1.local_state))
    do
      # no change to state! we don't allow to build upon uncommited transactions
      {:reply, response_check_tx(code: code(:ok)), %{abci_app | local_state: new_local_state}}
    else
      {:error, error} ->
        {:reply, response_check_tx(code: code(error), log: to_charlist(error)), abci_app}
    end
  end

  def handle_call(request_deliver_tx(tx: tx), _from, abci_app) do
    # NOTE: yes, we want to crash on invalid transactions, lol
    # there's a chore to fix that
    {:ok, decoded} = HonteD.TxCodec.decode(tx)
    {:ok, new_consensus_state} = handle_tx(abci_app, decoded, &(&1.consensus_state))
    HonteD.ABCI.Events.notify(new_consensus_state, decoded.raw_tx)
    {:reply, response_deliver_tx(code: code(:ok)), %{abci_app | consensus_state: new_consensus_state}}
  end

  @doc """
  Dissallow queries with non-empty-string data field for now
  """
  def handle_call(request_query(data: data), _from, abci_app) when data != "" do
    reply = response_query(code: code(:not_implemented), proof: 'no proof', log: 'unrecognized query')
    {:reply, reply, abci_app}
  end

  @doc """
  Not implemented: we don't yet support tendermint's standard queries to /store
  """
  def handle_call(request_query(path: '/store'), _from, abci_app) do
    reply = response_query(code: code(:not_implemented), proof: 'no proof',
      log: 'query to /store not implemented')
    {:reply, reply, abci_app}
  end

  @doc """
  Specific query for nonces which provides zero for unknown senders
  """
  def handle_call(request_query(path: '/nonces' ++ address), _from, abci_app) do
    key = "nonces" <> to_string(address)
    value = Map.get(abci_app.consensus_state, key, 0)
    reply = response_query(code: code(:ok), key: to_charlist(key), value: encode_query_response(value),
      proof: 'no proof')
    {:reply, reply, abci_app}
  end

  @doc """
  Specialized query for issued tokens for an issuer
  """
  def handle_call(request_query(path: '/issuers/' ++ address), _from, abci_app) do
    key = "issuers/" <> to_string(address)
    {code, value, log} = handle_get(State.issued_tokens(abci_app.consensus_state, address))
    reply = response_query(code: code, key: to_charlist(key),
      value: encode_query_response(value), proof: 'no proof', log: log)
    {:reply, reply, abci_app}
  end

  @doc """
  Generic raw query for any key in state.

  TODO: interface querying the state out, so that state remains implementation detail
  """
  def handle_call(request_query(path: path), _from, abci_app) do
    "/" <> key = to_string(path)
    {code, value, log} = lookup(abci_app.consensus_state, key)
    reply = response_query(code: code, key: to_charlist(key), value: encode_query_response(value),
      proof: 'no proof', log: log)
    {:reply, reply, abci_app}
  end

  def handle_call(request_init_chain(validators: [validator()]) = request, from, abci_app) do
    _ = Logger.warn("Warning: unhandled call from tendermint request: #{inspect request} from #{inspect from}")
    {:reply, response_init_chain(), abci_app}
  end

  ### END GenServer

  defp encode_query_response(object) do
    object
    |> Poison.encode!
    |> to_charlist
  end

  defp handle_tx(abci_app, %Transaction.SignedTx{raw_tx: %Transaction.EpochChange{}} = tx, extract_state)  do
    with :ok <- HonteD.Transaction.Validation.valid_signed?(tx),
         :ok <- HonteD.ABCI.EthereumContractState.validator_block_passed?(abci_app.contract_state),
         do: State.exec(extract_state.(abci_app), tx)
  end

  defp handle_tx(abci_app, tx, extract_state) do
    with :ok <- HonteD.Transaction.Validation.valid_signed?(tx),
         do: State.exec(extract_state.(abci_app), tx)
  end

  defp lookup(state, key) do
    state |> State.get(key) |> handle_get
  end

  defp handle_get({:ok, value}), do: {code(:ok), value, ''}
  defp handle_get(nil), do: {code(:not_found), "", 'not_found'}

  # NOTE: Define our own mapping from our error atoms to codes in range [1,...].
  #       See https://github.com/tendermint/abci/pull/145 and related.
  defp code(:ok), do: 0
  defp code(_), do: 1

end
