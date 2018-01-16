defmodule HonteD.ABCI.State do
  @moduledoc """
  Main workhorse of the `honted` ABCI app. Manages the state of the application replicated on the blockchain
  """
  alias HonteD.Transaction
  alias HonteD.Staking

  @max_amount round(:math.pow(2, 256))  # used to limit integers handled on-chain
  @epoch_number_key "contract/epoch_number"
  # indicates that epoch change is in progress, is set to true in epoch change transaction
  # and set to false when state is processed in EndBlock
  @epoch_change_key "contract/epoch_change"

  def initial do
    %{@epoch_number_key => 0, @epoch_change_key => false}
  end

  def get(state, key) do
    case state[key] do
      nil -> nil
      value -> {:ok, value}
    end
  end

  def issued_tokens(state, address) do
    key = "issuers/" <> to_string(address)
    case get(state, key) do
      {:ok, value} ->
        {:ok, value |> scan_potential_issued(state, to_string(address))}
      nil ->
        nil
    end
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.CreateToken{} = tx}) do

    with :ok <- nonce_valid?(state, tx.issuer, tx.nonce),
         do: {:ok, state
                   |> apply_create_token(tx.issuer, tx.nonce)
                   |> bump_nonce_after(tx)}
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.Issue{} = tx}) do

    with :ok <- nonce_valid?(state, tx.issuer, tx.nonce),
         :ok <- is_issuer?(state, tx.asset, tx.issuer),
         :ok <- not_too_much?(tx.amount, state["tokens/#{tx.asset}/total_supply"]),
         do: {:ok, state
                   |> apply_issue(tx.asset, tx.amount, tx.dest)
                   |> bump_nonce_after(tx)}
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.Send{} = tx}) do
    key_src = "accounts/#{tx.asset}/#{tx.from}"
    key_dest = "accounts/#{tx.asset}/#{tx.to}"

    with :ok <- nonce_valid?(state, tx.from, tx.nonce),
         :ok <- account_has_at_least?(state, key_src, tx.amount),
         do: {:ok, state
                  |> apply_send(tx.amount, key_src, key_dest)
                  |> bump_nonce_after(tx)}
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.SignOff{} = tx}) do
    with :ok <- nonce_valid?(state, tx.sender, tx.nonce),
         :ok <- allows_for?(state, tx.signoffer, tx.sender, :signoff),
         :ok <- sign_off_incremental?(state, tx.height, tx.signoffer),
         do: {:ok, state
                   |> apply_sign_off(tx.height, tx.hash, tx.signoffer)
                   |> bump_nonce_after(tx)}
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.Allow{} = tx}) do
    with :ok <- nonce_valid?(state, tx.allower, tx.nonce),
         do: {:ok, state
                   |> apply_allow(tx.allower, tx.allowee, tx.privilege, tx.allow)
                   |> bump_nonce_after(tx)}
  end

  def exec(state, %Transaction.SignedTx{raw_tx: %Transaction.EpochChange{} = tx},
   %Staking{} = staking_state) do
    with :ok <- nonce_valid?(state, tx.sender, tx.nonce),
         :ok <- Staking.validator_block_passed?(staking_state, state[@epoch_number_key]),
         :ok <- epoch_valid?(state, tx.epoch_number),
         do: {:ok, state
                   |> apply_epoch_change
                   |> bump_nonce_after(tx)}
  end

  defp epoch_valid?(state, epoch_number) do
    is_next_epoch = state[@epoch_number_key] == epoch_number - 1
    if is_next_epoch and not state[@epoch_change_key], do: :ok, else: {:error, :invalid_epoch_change}
  end

  defp account_has_at_least?(state, key_src, amount) do
    if Map.get(state, key_src, 0) >= amount, do: :ok, else: {:error, :insufficient_funds}
  end

  defp nonce_valid?(state, src, nonce) do
    if Map.get(state, "nonces/#{src}", 0) == nonce, do: :ok, else: {:error, :invalid_nonce}
  end

  defp not_too_much?(amount_entering, amount_present)
  when amount_entering >= 0 and
       amount_present >= 0 do
    # limits the ability to exploit BEAM's uncapped integer in an attack.
    # Has nothing to do with token supply mechanisms
    # NOTE: this is a stateful test,
    # the state-less test is better handled by limitting the tx's byte-size
    if amount_entering + amount_present < @max_amount, do: :ok, else: {:error, :amount_way_too_large}
  end

  defp is_issuer?(state, token_addr, address) do
    case Map.get(state, "tokens/#{token_addr}/issuer") do
      nil -> {:error, :unknown_issuer}
      ^address -> :ok
      _ -> {:error, :incorrect_issuer}
    end
  end

  defp sign_off_incremental?(state, height, sender) do
    case Map.get(state, "sign_offs/#{sender}") do
      nil -> :ok  # first sign off ever always correct
      %{height: old_height} when is_integer(old_height) and old_height < height -> :ok
      %{height: old_height} when is_integer(old_height) -> {:error, :sign_off_not_incremental}
    end
  end

  defp allows_for?(state, allower, allowee, privilege) when is_atom(privilege) do
    # checks whether allower allows allowee for privilege

    # always self-allow and in case allower != allowee - check delegations in state
    if allower == allowee or Map.get(state, "delegations/#{allower}/#{allowee}/#{privilege}") do
      :ok
    else
      {:error, :invalid_delegation}
    end
  end

  defp apply_create_token(state, issuer, nonce) do
    token_addr = HonteD.Token.create_address(issuer, nonce)
    state
    |> Map.put("tokens/#{token_addr}/issuer", issuer)
    |> Map.put("tokens/#{token_addr}/total_supply", 0)
    # NOTE: check for duplicate entries or don't care?
    |> Map.update("issuers/#{issuer}", [token_addr], fn previous -> [token_addr | previous] end)
  end

  defp apply_issue(state, asset, amount, dest) do
    key_dest = "accounts/#{asset}/#{dest}"
    state
    |> Map.update(key_dest, amount, &(&1 + amount))
    |> Map.update("tokens/#{asset}/total_supply", amount, &(&1 + amount))
  end

  defp apply_send(state, amount, key_src, key_dest) do
    state
    |> Map.update!(key_src, &(&1 - amount))
    |> Map.update(key_dest, amount, &(&1 + amount))
  end

  defp apply_sign_off(state, height, hash, signoffer) do
    state
    |> Map.put("sign_offs/#{signoffer}", %{height: height, hash: hash})
  end

  defp apply_allow(state, allower, allowee, privilege, allow) do
    state
    |> Map.put("delegations/#{allower}/#{allowee}/#{privilege}", allow)
  end

  defp apply_epoch_change(state) do
    state
    |> Map.update!(@epoch_change_key, fn _ -> true end)
    |> Map.update!(@epoch_number_key, &(&1 + 1))
  end

  defp bump_nonce_after(state, tx) do
    sender = Transaction.Validation.sender(tx)
    state
    |> Map.update("nonces/#{sender}", 1, &(&1 + 1))
  end

  def hash(state) do
    # NOTE: crudest of all app state hashes
    state
    |> OJSON.encode!  # using OJSON instead of inspect to have crypto-ready determinism
    |> HonteD.Crypto.hash
  end

  defp scan_potential_issued(unfiltered_tokens, state, issuer) do
    unfiltered_tokens
    |> Enum.filter(fn token_addr -> state["tokens/#{token_addr}/issuer"] == issuer end)
  end

  def epoch_change?(state) do
    state[@epoch_change_key]
  end

  def not_change_epoch(state) do
    Map.update!(state, @epoch_change_key, fn _ -> false end)
  end

  def epoch_number(state) do
    state[@epoch_number_key]
  end

end
