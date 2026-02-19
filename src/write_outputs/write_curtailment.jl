"""
Curtailment outputs - everything related to VRE curtailment data extraction and output.
"""

## Write curtailment outputs ##
# This is the main function to write the curtailment outputs to a file.

"""
    write_curtailment(
        file_path::AbstractString, 
        system::System; 
        scaling::Float64=1.0, 
        drop_cols::Vector{<:AbstractString}=String[]
    )

Write the optimal curtailment results for all VRE assets in a system to a file.
Curtailment is the difference between potential VRE generation
(availability × capacity) and actual generation (flow).
The extension of the file determines the format of the file.

# Arguments
- `file_path::AbstractString`: The path to the file where the results will be written
- `system::System`: The system containing the VRE assets to analyze as well as the settings for the output
- `scaling::Float64`: The scaling factor for the results
- `drop_cols::Vector{<:AbstractString}`: Columns to drop from the DataFrame

# Returns
- `nothing`: The function returns nothing, but writes the results to the file

# Example
```julia
write_curtailment("curtailment.csv", system)
```
"""
function write_curtailment(
    file_path::AbstractString,
    system::System;
    scaling::Float64=1.0,
    drop_cols::Vector{<:AbstractString}=String[]
)
    @info "Writing curtailment results to $file_path"

    # Get curtailment results and determine layout (wide or long)
    curtailment_results = get_optimal_curtailment(system; scaling)
    layout = get_output_layout(system, :Curtailment)

    if layout == "wide"
        # df will be of size (time_steps, component_ids)
        curtailment_results = reshape_wide(curtailment_results, :time, :component_id, :value)
    end
    write_dataframe(file_path, curtailment_results, drop_cols)
    return nothing
end

# Function to write curtailment results from multiple dataframes
# This function is used when the results are distributed across multiple processes
function write_curtailments(
    file_path::AbstractString,
    system::System,
    curtailment_dfs::Vector{DataFrame}
)
    @info("Writing curtailment results to $file_path")

    # Concatenate curtailment results from subproblems belonging to the same period
    curtailment_results = reduce(vcat, curtailment_dfs)

    # Reshape if wide layout requested
    layout = get_output_layout(system, :Curtailment)
    if layout == "wide"
        curtailment_results = reshape_wide(curtailment_results, :time, :component_id, :value)
    end
    write_dataframe(file_path, curtailment_results)
end

## Curtailment extraction functions ##
"""
    get_optimal_curtailment(system::System; scaling::Float64=1.0)

Get the optimal curtailment values for all VRE assets in a system.
Curtailment is calculated as `availability(e, t) × capacity(e) - flow(e, t)` for each
VRE edge at each time step.

# Arguments
- `system::System`: The system containing the VRE assets to analyze
- `scaling::Float64`: The scaling factor for the results.

# Returns
- `DataFrame`: A dataframe containing the curtailment values for all VRE edges,
  with missing columns removed

# Example
```julia
get_optimal_curtailment(system)
12×10 DataFrame
 Row │ commodity    zone     resource_id        component_id            resource_type  component_type     variable     time   value
     │ Symbol       Symbol   Symbol             Symbol                  String         String             Symbol       Int64  Float64
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ Electricity  elec_SE  existing_solar_SE  existing_solar_SE_edge  VRE            Edge{Electricity}  curtailment  1      0.0
   2 │ Electricity  elec_SE  existing_solar_SE  existing_solar_SE_edge  VRE            Edge{Electricity}  curtailment  2      1.5
   3 │ Electricity  elec_SE  existing_solar_SE  existing_solar_SE_edge  VRE            Edge{Electricity}  curtailment  3      0.0
```
"""
function get_optimal_curtailment(system::System; scaling::Float64=1.0)
    @debug " -- Getting optimal curtailment values for VRE assets in the system"
    vre_assets = filter(a -> isa(a, VRE), system.assets)
    if isempty(vre_assets)
        return DataFrame()
    end
    edges, edge_asset_map = get_edges(vre_assets; return_ids_map=true)
    curtailment = get_optimal_curtailment(edges, scaling, edge_asset_map)
    curtailment[!, (!isa).(eachcol(curtailment), Vector{Missing})] # remove missing columns
end

## Timeseries curtailment extraction functions ##
# The following functions are used to extract curtailment values after the model has been solved
# from a list of VRE edges
function get_optimal_curtailment(
    objs::Vector{<:AbstractEdge},
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    isempty(objs) && return DataFrame()
    reduce(vcat, [get_optimal_curtailment(o, scaling, obj_asset_map) for o in objs])
end

function get_optimal_curtailment(
    obj::AbstractEdge,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    time_axis = time_interval(obj)
    if isempty(obj_asset_map)
        return DataFrame(
            case_name = fill(missing, length(time_axis)),
            commodity = fill(get_commodity_name(obj), length(time_axis)),
            node_in = fill(get_node_in(obj), length(time_axis)),
            node_out = fill(get_node_out(obj), length(time_axis)),
            resource_id = fill(get_component_id(obj), length(time_axis)),
            component_id = fill(get_component_id(obj), length(time_axis)),
            component_type = fill(get_type(obj), length(time_axis)),
            variable = :curtailment,
            year = fill(missing, length(time_axis)),
            time = [t for t in time_axis],
            value = [
                (availability(obj, t) * value(capacity(obj)) - value(flow(obj, t))) * scaling
                for t in time_axis
            ]
        )
    else
        return DataFrame(
            case_name = fill(missing, length(time_axis)),
            commodity = fill(get_commodity_name(obj), length(time_axis)),
            node_in = fill(get_node_in(obj), length(time_axis)),
            node_out = fill(get_node_out(obj), length(time_axis)),
            resource_id = fill(get_resource_id(obj, obj_asset_map), length(time_axis)),
            component_id = fill(get_component_id(obj), length(time_axis)),
            resource_type = fill(get_type(obj_asset_map[id(obj)]), length(time_axis)),
            component_type = fill(get_type(obj), length(time_axis)),
            variable = :curtailment,
            year = fill(missing, length(time_axis)),
            time = [t for t in time_axis],
            value = [
                (availability(obj, t) * value(capacity(obj)) - value(flow(obj, t))) * scaling
                for t in time_axis
            ]
        )
    end
end
