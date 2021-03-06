#   Copyright 2018 OmiseGO Pte Ltd
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

defmodule HonteD.ABCITest do
  @moduledoc """
  **NOTE** this test will pretend to be Tendermint core
  """
  # NOTE: we can't enforce this here, because of the keyword-list-y form of create_x calls
  # credo:disable-for-this-file Credo.Check.Refactor.PipeChainStart

  use ExUnitFixtures
  use ExUnit.Case, async: true

  import HonteD.ABCI.TestHelpers
  import HonteD.ABCI.Records

  import HonteD.ABCI
  import HonteD.Transaction

  describe "info requests from tendermint" do
    @tag fixtures: [:empty_state]
    test "info about clean state", %{empty_state: state} do
      assert {:reply, response_info(last_block_height: 0), ^state} =
        handle_call(request_info(), nil, state)
    end
  end

  describe "checkTx" do
    @tag fixtures: [:issuer, :empty_state]
    test "builds upon state modified by dependent transaction",
      %{empty_state: state, issuer: issuer} do
      %{state: state} =
        create_create_token(nonce: 0, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> check_tx(state) |> success?
      asset = HonteD.Token.create_address(issuer.addr, 0)
      %{state: ^state} =
        create_issue(nonce: 0, asset: asset, amount: 1, dest: issuer.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> check_tx(state) |> fail?(1, 'invalid_nonce')
      %{state: _} =
        create_issue(nonce: 1, asset: asset, amount: 1, dest: issuer.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> check_tx(state) |> success?
    end
  end

  describe "commits" do
    @tag fixtures: [:issuer, :empty_state]
    test "hash from commits changes on state update", %{empty_state: state, issuer: issuer} do
      assert {:reply, {:ResponseCommit, 0, cleanhash, _}, ^state} = handle_call({:RequestCommit}, nil, state)

      %{state: state} =
        create_create_token(nonce: 0, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      assert {:reply, {:ResponseCommit, 0, newhash, _}, _} = handle_call({:RequestCommit}, nil, state)
      assert newhash != cleanhash
    end

    @tag fixtures: [:issuer, :empty_state]
    test "commit overwrites local state with consensus state", %{empty_state: state, issuer: issuer} do
      %{state: updated_state} =
        create_create_token(nonce: 0, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> check_tx(state) |> success?
      assert updated_state != state

      # No deliverTx transactions were applied since last commit;
      # this should drop part of state related to checkTx, reverting
      # ABCI state to its initial value.
      assert {:reply, {:ResponseCommit, 0, _, _}, ^state} =
        handle_call({:RequestCommit}, nil, updated_state)
    end
  end

  describe "generic transaction checks" do
    @tag fixtures: [:empty_state]
    test "too large transactions throw", %{empty_state: state} do
      String.duplicate("a", 1024)
      |> ExRLP.encode()
      |> Base.encode16()
      |> deliver_tx(state) |> fail?(1, 'transaction_too_large') |> same?(state)
    end
  end

  describe "unhandled query clauses" do
    @tag fixtures: [:empty_state]
    test "queries to /store are verbosely unimplemented", %{empty_state: state} do
      # NOTE: this will naturally go away, if we decide to implement /store
      assert {:reply, {:ResponseQuery, 1, _, _, _, _, _, 'query to /store not implemented'}, ^state} =
        handle_call({:RequestQuery, "", '/store', 0, :false}, nil, state)
    end
  end

end
