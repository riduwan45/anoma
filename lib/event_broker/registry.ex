defmodule EventBroker.Registry do
  @moduledoc """
  an event broker registry
  """

  alias __MODULE__

  use GenServer
  use TypedStruct

  typedstruct enforce: true do
    field(:registered_filters, %{list(struct()) => pid()}, default: %{})
  end

  def start_link(top_level_pid) do
    GenServer.start_link(__MODULE__, top_level_pid, name: __MODULE__)
  end

  def init(top_level_pid) do
    {:ok, %Registry{registered_filters: %{[] => top_level_pid}}}
  end

  ############################################################
  #                      Public RPC API                      #
  ############################################################

  def subscribe(pid, filter_spec_list) do
    GenServer.call(__MODULE__, {:subscribe, pid, filter_spec_list})
  end

  def subscribe_me(filter_spec_list) do
    subscribe(self(), filter_spec_list)
  end

  def unsubscribe(pid, filter_spec_list) do
    GenServer.call(__MODULE__, {:unsubscribe, pid, filter_spec_list})
  end

  def unsubscribe_me(filter_spec_list) do
    unsubscribe(self(), filter_spec_list)
  end

  ############################################################
  #                    Genserver Behavior                    #
  ############################################################

  def handle_call({:subscribe, pid, filter_spec_list}, _from, state) do
    invalid_filters =
      filter_spec_list
      |> Enum.flat_map(fn spec ->
        struct = spec.__struct__

        if Kernel.function_exported?(struct, :filter, 2) do
          []
        else
          [struct]
        end
      end)

    if Enum.empty?(invalid_filters) do
      new_state =
        if Map.has_key?(state.registered_filters, filter_spec_list) do
          state
        else
          existing_prefix =
            state.registered_filters
            |> Map.keys()
            |> Enum.filter(fn p -> List.starts_with?(filter_spec_list, p) end)
            |> Enum.sort(&(length(&1) > length(&2)))
            |> hd()

          remaining_to_spawn = filter_spec_list -- existing_prefix

          # ["a", "b"] -> ["a", "b", "c", "d"]
          # {["a", "b"], state} iterating over "c"
          # {["a", "b", "c"], state + ["a", "b", "c"] iterating over "d"

          {_, new_registered_filters} =
            for f <- remaining_to_spawn,
                reduce: {existing_prefix, state.registered_filters} do
              {parent_spec_list, old_state} ->
                parent_pid = Map.get(old_state, parent_spec_list)

                {:ok, new_pid} =
                  GenServer.start_link(
                    EventBroker.FilterAgent,
                    f
                  )

                GenServer.call(parent_pid, {:subscribe, new_pid})
                new_spec_list = parent_spec_list ++ [f]
                new_state = Map.put(old_state, new_spec_list, new_pid)
                {new_spec_list, new_state}
            end

          %{state | registered_filters: new_registered_filters}
        end

      GenServer.call(
        Map.get(new_state.registered_filters, filter_spec_list),
        {:subscribe, pid}
      )

      {:reply, :ok, new_state}
    else
      {:reply,
       "#{inspect(invalid_filters)} do not export filtering functions", state}
    end
  end

  def handle_call({:unsubscribe, pid, filter_spec_list}, _from, state) do
    GenServer.call(
      Map.get(state.registered_filters, filter_spec_list),
      {:unsubscribe, pid}
    )

    {:reply, :ok, state}
  end

  def handle_call(:dump, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast({:delist, filter}, _from, state) do
    filters = state.registered_filters

    {spec, pid} = find_filter_info(filters, filter)

    parent = spec |> List.delete(filter)

    filters |> Map.get(parent) |> GenServer.call({:unsubscribe, pid})

    {:noreply, %{state | subscribers: Map.delete(filters, filter)}}
  end

  def find_filter_info(filters, filter) do
    filters
    |> Enum.find(fn {key, _val} ->
      List.last(key) == filter
    end)
  end
end
