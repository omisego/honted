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

defmodule HonteD.ABCI.Ethereum.Ethash do
  @moduledoc """
  Implements Ethash.
  Based on pyethereum and Ethash wiki(https://github.com/ethereum/wiki/wiki/Ethash)
  """
  use Bitwise

  alias HonteD.ABCI.Ethereum.EthashUtils

  @fnv_prime 16_777_619
  @base_32 4_294_967_296 # 2^32
  @hash_bytes 64
  @dataset_parents 256
  @dataset_mix_range 16 # @hash_bytes / @word_bytes
  @mix_hashes 2 # @mix_bytes / @hash_bytes
  @words 32 # @mix_bytes / @word_bytes
  @accesses 64

  @type cache_line_t :: list(non_neg_integer())
  @type cache_t :: %{non_neg_integer() => cache_line_t}
  @type hashimoto_result_t :: [{:mix_digest, binary()}, {:result, binary()}]

  @doc """
  Returns mix digest and hash result for given header and nonce
  """
  @spec hashimoto_light(integer(), cache_t, binary(), binary()) :: hashimoto_result_t
  def hashimoto_light(full_size, cache, header, nonce) do
    hashimoto(header, nonce, full_size, fn x -> calc_dataset_item(cache, x) end)
  end

  defp hashimoto(header, nonce, full_size, dataset_lookup) do
    n = div(full_size, @hash_bytes)
    nonce_le = nonce_little_endian(nonce)

    seed = EthashUtils.keccak_512(header <> nonce_le)
    compressed_mix =
      seed
      |> List.duplicate(@mix_hashes)
      |> List.flatten
      |> mix_in_dataset(seed, dataset_lookup, n, 0)
      |> compress([])
    [mix_digest: EthashUtils.encode_ints(compressed_mix),
     result: EthashUtils.encode_ints(EthashUtils.keccak_256(seed ++ compressed_mix))]
  end

  defp nonce_little_endian(nonce) do
    nonce_little_endian = Enum.reverse(:binary.bin_to_list(nonce))
    :binary.list_to_bin(nonce_little_endian)
  end

  defp mix_in_dataset(mix, _seed, _dataset_lookup, _n, @accesses), do: mix
  defp mix_in_dataset(mix, seed, dataset_lookup, n, i) do
    mix_index = div(n, @mix_hashes)
    p = rem(fnv(i ^^^ Enum.at(seed, 0), Enum.at(mix, rem(i, @words))), mix_index) * @mix_hashes
    new_data = get_new_data([], p, dataset_lookup, 0)

    mix_with_data = Enum.zip(mix, new_data)
    mix = Enum.map(mix_with_data, fn {a, b} -> fnv(a, b) end)
    mix_in_dataset(mix, seed, dataset_lookup, n, i + 1)
  end

  defp get_new_data(acc, _p, _dataset_lookup, @mix_hashes), do: acc
  defp get_new_data(acc, p, dataset_lookup, j) do
    get_new_data(acc ++ dataset_lookup.(p + j), p, dataset_lookup, j + 1)
  end

  defp compress([], compressed_mix), do: Enum.reverse(compressed_mix)
  defp compress(mix, compressed_mix) do
    [m1, m2, m3, m4 | tail] = mix
    c = fnv(fnv(fnv(m1, m2), m3), m4)
    compress(tail, [c | compressed_mix])
  end

  defp calc_dataset_item(cache, i) do
    n = map_size(cache)
    [head | tail] = cache[rem(i, n)]
    initial = EthashUtils.keccak_512([head ^^^ i | tail])
    mixed = mix(cache, i, initial, 0)

    EthashUtils.keccak_512(mixed)
  end

  defp mix(_cache, _i, current_mix, @dataset_parents), do: current_mix
  defp mix(cache, i, current_mix, j) do
    cache_index = fnv(i ^^^ j, Enum.at(current_mix, rem(j, @dataset_mix_range)))
    mixed_with_cache = Enum.zip(current_mix, cache[rem(cache_index, map_size(cache))])
    current_mix = Enum.map(mixed_with_cache, fn {a, b} -> fnv(a, b) end)
    mix(cache, i, current_mix, j + 1)
  end

  defp fnv(v1, v2) do
    rem((v1 * @fnv_prime) ^^^ v2, @base_32)
  end

end
