"""
VRE curtailment outputs - everything related to curtailment data extraction and output.

Curtailment is the difference between the potential generation of a VRE asset
(availability × capacity) and its actual output (flow). VRE resources may be
dispatched at less than their potential generation due to grid constraints.
"""

## Write curtailment outputs ##

"""
    write_curtailment(
        file_path::AbstractString,
        system::System;
        scaling::Float64=1.0,
        drop_cols::Vector{<:AbstractString}=String[]
    )

Write the VRE curtailment results for the system to a file.
The extension of the file determines the format of the file.

Curtailment is defined as the difference between potential generation
(availability × capacity) and actual generation (flow) for each VRE asset.

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

    curtailment_results = get_optimal_curtailment(system; scaling)
    layout = get_output_layout(system, :Curtailment)

    if layout == "wide"
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

Get the VRE curtailment values for all VRE assets in a system.

Curtailment is the difference between potential generation
(availability × capacity) and actual generation (flow) for each VRE edge
at each timestep.

# Arguments
- `system::System`: The system containing the VRE assets to analyze
- `scaling::Float64`: The scaling factor for the results.

# Returns
- `DataFrame`: A dataframe containing the curtailment values for all VRE edges,
  with missing columns removed

# Example
```julia
get_optimal_curtailment(system)
12×9 DataFrame
 Row │ commodity    node_in              node_out  resource_id    component_id         resource_type  component_type     variable      time   value
     │ Symbol       Symbol               Symbol    Symbol         Symbol               String         String             Symbol        Int64  Float64
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ Electricity  MA_solar_pv_transfo…  elec_MA   MA_solar_pv    MA_solar_pv_edge     VRE            Edge{Electricity}  curtailment   1      0.0
   2 │ Electricity  MA_solar_pv_transfo…  elec_MA   MA_solar_pv    MA_solar_pv_edge     VRE            Edge{Electricity}  curtailment   2      5.2
```
"""
function get_optimal_curtailment(system::System; scaling::Float64=1.0)
    @debug " -- Getting curtailment values for the system"
    vre_assets = filter(a -> isa(a, VRE), system.assets)
    if isempty(vre_assets)
        @warn "No VRE assets found in the system"
        return DataFrame()
    end
    edges, edge_asset_map = get_edges(vre_assets, return_ids_map=true)
    curtailment = get_optimal_curtailment(edges, scaling, edge_asset_map)
    curtailment[!, (!isa).(eachcol(curtailment), Vector{Missing})] # remove missing columns
end

"""
    get_optimal_curtailment(
        edges::Vector{<:AbstractEdge},
        scaling::Float64=1.0,
        edge_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
    )

Compute curtailment for a list of VRE edges.

# Arguments
- `edges::Vector{<:AbstractEdge}`: The VRE edges to analyze
- `scaling::Float64`: The scaling factor for the results
- `edge_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}`: Map from edge IDs to their parent assets

# Returns
- `DataFrame`: A dataframe containing the curtailment values
"""
function get_optimal_curtailment(
    edges::Vector{<:AbstractEdge},
    scaling::Float64=1.0,
    edge_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    reduce(vcat, [get_optimal_curtailment(e, scaling, edge_asset_map) for e in edges])
end

"""
    get_optimal_curtailment(
        obj::AbstractEdge,
        scaling::Float64=1.0,
        obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
    )

Compute curtailment for a single VRE edge.

Curtailment at each timestep `t` is:
```math
\\text{curtailment}(e, t) = \\max(0, \\text{availability}(e, t) \\times \\text{capacity}(e) - \\text{flow}(e, t))
```

# Arguments
- `obj::AbstractEdge`: The VRE edge to analyze
- `scaling::Float64`: The scaling factor for the results
- `obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}`: Map from edge IDs to their parent assets

# Returns
- `DataFrame`: A dataframe with one row per timestep containing the curtailment value
"""
function get_optimal_curtailment(
    obj::AbstractEdge,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    time_axis = time_interval(obj)
    cap = value(capacity(obj))
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
            value = [max(0.0, availability(obj, t) * cap - value(flow(obj, t))) * scaling for t in time_axis]
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
            value = [max(0.0, availability(obj, t) * cap - value(flow(obj, t))) * scaling for t in time_axis]
        )
    end
end
