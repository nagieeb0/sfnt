defmodule Sfnt.Charstring do
  @moduledoc """
  Just enough Type 2 charstring parsing to find which subroutines a glyph uses.

  Subroutines are shared fragments of outline that charstrings call into. They
  are big — 13 KB of the 158 KB brand face this was written for, larger than
  everything except the outlines themselves — and a glyph that is no longer
  drawn stops needing them.

  Finding the calls means parsing the bytecode, and the awkward part is
  `hintmask`: it is followed by a run of mask bytes whose length depends on how
  many stem hints have been declared so far, and stems can be declared
  implicitly by leaving operands on the stack before it. Miscount and every
  byte after is misread.
  """

  import Bitwise

  @callsubr 10
  @callgsubr 29
  @hintmask 19
  @cntrmask 20
  @hstem 1
  @vstem 3
  @hstemhm 18
  @vstemhm 23
  @endchar 14
  @rmoveto 21
  @hmoveto 22
  @vmoveto 4

  @doc """
  Collects every local and global subroutine reachable from `charstrings`,
  following calls transitively.

  Returns `{local_indices, global_indices}` as `MapSet`s of INDEX positions,
  already un-biased.
  """
  @spec used_subrs([binary()], [binary()], [binary()]) :: {MapSet.t(), MapSet.t()}
  def used_subrs(charstrings, local_subrs, global_subrs) do
    state = %{
      locals: local_subrs,
      globals: global_subrs,
      local_bias: bias(length(local_subrs)),
      global_bias: bias(length(global_subrs))
    }

    Enum.reduce(charstrings, {MapSet.new(), MapSet.new()}, fn cs, acc ->
      scan(cs, state, acc, [], 0)
    end)
  end

  @doc """
  The Type 2 subroutine index bias, which lets small operands address the
  middle of a large INDEX.
  """
  @spec bias(non_neg_integer()) :: integer()
  def bias(count) when count < 1240, do: 107
  def bias(count) when count < 33_900, do: 1131
  def bias(_count), do: 32_768

  # `stack` is the operand stack (most recent first) and `stems` the running
  # count of declared stem hints, which sets the width of a hintmask.
  defp scan(<<>>, _state, acc, _stack, _stems), do: acc

  defp scan(<<op, rest::binary>>, state, acc, stack, stems) when op in [@hintmask, @cntrmask] do
    # Operands still on the stack before a mask are an implicit vstem.
    stems = stems + div(length(stack), 2)
    skip = div(stems + 7, 8)

    case rest do
      <<_mask::binary-size(^skip), tail::binary>> -> scan(tail, state, acc, [], stems)
      _ -> acc
    end
  end

  defp scan(<<op, rest::binary>>, state, acc, stack, stems)
       when op in [@hstem, @vstem, @hstemhm, @vstemhm] do
    scan(rest, state, acc, [], stems + div(length(stack), 2))
  end

  defp scan(<<@callsubr, rest::binary>>, state, acc, stack, stems) do
    follow(:local, rest, state, acc, stack, stems)
  end

  defp scan(<<@callgsubr, rest::binary>>, state, acc, stack, stems) do
    follow(:global, rest, state, acc, stack, stems)
  end

  defp scan(<<@endchar, _rest::binary>>, _state, acc, _stack, _stems), do: acc

  # Operands. Everything else clears the stack, which is all this needs to
  # know about the drawing operators themselves.
  defp scan(<<28, v::signed-16, rest::binary>>, state, acc, stack, stems),
    do: scan(rest, state, acc, [v | stack], stems)

  defp scan(<<255, v::signed-32, rest::binary>>, state, acc, stack, stems),
    do: scan(rest, state, acc, [bsr(v, 16) | stack], stems)

  defp scan(<<b0, rest::binary>>, state, acc, stack, stems) when b0 in 32..246,
    do: scan(rest, state, acc, [b0 - 139 | stack], stems)

  defp scan(<<b0, b1, rest::binary>>, state, acc, stack, stems) when b0 in 247..250,
    do: scan(rest, state, acc, [(b0 - 247) * 256 + b1 + 108 | stack], stems)

  defp scan(<<b0, b1, rest::binary>>, state, acc, stack, stems) when b0 in 251..254,
    do: scan(rest, state, acc, [-(b0 - 251) * 256 - b1 - 108 | stack], stems)

  # Moveto operators can carry a leading width argument, but they do not
  # declare stems, so the stack simply clears.
  defp scan(<<op, rest::binary>>, state, acc, _stack, stems)
       when op in [@rmoveto, @hmoveto, @vmoveto],
       do: scan(rest, state, acc, [], stems)

  defp scan(<<12, _op2, rest::binary>>, state, acc, _stack, stems),
    do: scan(rest, state, acc, [], stems)

  defp scan(<<_op, rest::binary>>, state, acc, _stack, stems),
    do: scan(rest, state, acc, [], stems)

  defp follow(kind, rest, state, {locals, globals}, stack, stems) do
    {subrs, bias, already} =
      case kind do
        :local -> {state.locals, state.local_bias, locals}
        :global -> {state.globals, state.global_bias, globals}
      end

    case stack do
      [operand | tail] when is_integer(operand) ->
        index = operand + bias

        acc =
          if index >= 0 and index < length(subrs) and not MapSet.member?(already, index) do
            marked =
              case kind do
                :local -> {MapSet.put(locals, index), globals}
                :global -> {locals, MapSet.put(globals, index)}
              end

            # Recurse into the subroutine: subrs call other subrs.
            scan(Enum.at(subrs, index), state, marked, [], stems)
          else
            {locals, globals}
          end

        scan(rest, state, acc, tail, stems)

      _ ->
        scan(rest, state, {locals, globals}, [], stems)
    end
  end
end
