defmodule MobCi.Lane.Ios.Tee do
  @moduledoc """
  A `Collectable` for `System.cmd/3`'s `:into`: every chunk is echoed to
  stdout as it arrives (so a long build streams), appended to `file` when one
  is open (the NUC's log of an ssh session), and the last `max` bytes are kept
  for a failure's detail.
  """

  defstruct tail: "", max: 2_000, echo: true, file: nil

  @type t :: %__MODULE__{
          tail: String.t(),
          max: pos_integer(),
          echo: boolean(),
          file: IO.device() | nil
        }

  defimpl Collectable do
    def into(tee) do
      fun = fn
        acc, {:cont, chunk} ->
          if acc.echo, do: IO.binwrite(chunk)
          if acc.file, do: IO.binwrite(acc.file, chunk)
          tail = acc.tail <> chunk
          size = byte_size(tail)
          tail = if size > acc.max, do: binary_part(tail, size - acc.max, acc.max), else: tail
          %{acc | tail: tail}

        acc, :done ->
          # A byte-count cut can land inside a multibyte character (✓ ✗ │ in
          # mob's output); the tail goes into JSON, so it must be valid UTF-8.
          %{acc | tail: String.replace_invalid(acc.tail, "")}

        _acc, :halt ->
          :ok
      end

      {tee, fun}
    end
  end
end
