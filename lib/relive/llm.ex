defmodule Relive.LLM do
  use Membrane.Filter

  alias Relive.Audio.RawText

  require Logger

  def_options(
    system_prompt: [
      spec: String.t(),
      description: "The system prompt for the assistant."
    ],
    serving: [
      spec: atom() | pid(),
      description: "Which serving to use for generating text."
    ]
  )

  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawText
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawText
  )

  @impl true
  def handle_init(_ctx, mod) do
    state = %{opts: mod, exchange: []}
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, 1}, stream_format: {:output, %RawText{}}], state}
  end

  @impl true
  def handle_stream_format(_, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{payload: text},
        _ctx,
        state
      ) do
    state = %{state | exchange: [{:user, text} | state.exchange]}
    %{results: chunks} = generate(state.opts.serving, state.exchange, state.opts.system_prompt)
    out_text = to_raw_text(chunks)
    state = %{state | exchange: [{:assistant, out_text} | state.exchange]}
    new_buffer = %Membrane.Buffer{payload: out_text}
    {[notify_parent: {:assistant, state.exchange}, buffer: {:output, new_buffer}], state}
  end

  @repo {:hf, "HuggingFaceTB/SmolLM2-135M-Instruct"}
  def serving(top_p \\ 0.6) do
    {:ok, model_info} = Bumblebee.load_model(@repo, type: :bf16)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(@repo)
    {:ok, generation_config} = Bumblebee.load_generation_config(@repo)

    generation_config =
      Bumblebee.configure(generation_config,
        max_new_tokens: 100,
        strategy: %{type: :multinomial_sampling, top_p: top_p}
      )

    Bumblebee.Text.generation(
      model_info,
      tokenizer,
      generation_config
      # compile: [batch_size: 1, sequence_length: 1028],
      # stream: true
    )
  end

  def generate(name, exchange, system_prompt) do
    {t, output} =
      :timer.tc(fn ->
        Nx.Serving.batched_run(name, prompt(exchange, system_prompt))
        |> IO.inspect(label: "Result text")
      end)

    Logger.info("Generated output in #{t / 1000}ms.")
    output
  end

  def warmup do
    IO.puts("Warming up LLM...")
    generate(Relive.LLM, [{:user, ""}], "")
    IO.puts("LLM warmed up.")
  end

  defp prompt(exchange, system_prompt) do
    IO.puts("Exchange:")

    exchange
    |> Enum.reverse()
    |> Enum.map(fn {actor, text} ->
      "#{actor}: #{text}"
    end)
    |> Enum.join("\n")
    |> IO.puts()

    text =
      exchange
      |> Enum.reverse()
      |> Enum.take(4)
      |> Enum.map(fn {actor, text} ->
        """
        <|im_start|>#{actor}
        #{text}
        <|im_end|>
        """
      end)
      |> Enum.join("\n")

    """
    <|im_start|>system
    #{system_prompt}
    <|im_end|>
    #{text}
    <|im_start|>assistant
    """
  end

  defp to_raw_text(chunks) do
    chunks
    |> Enum.map(&String.trim(&1.text))
  end
end
