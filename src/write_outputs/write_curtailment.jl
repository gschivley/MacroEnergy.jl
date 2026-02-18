"""
Curtailment outputs - everything related to curtailment data extraction and output.
"""

## Write curtailment outputs ##
# This is the main function to write the curtailment outputs to a file.

"""
    write_curtailment(
        file_path::AbstractString, 
        system::System; 
        scaling::Float64=1.0, 
        drop_cols::Vector{<:AbstractString}=String[],
        commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing,
        asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
    )

Write the curtailment results for the system to a file.
The extension of the file determines the format of the file.

Curtailment is the difference between available capacity and actual generation:
curtailment = availability(e,t) * capacity(e) - flow(e,t)

Curtailment is only calculated for edges with capacity constraints.

## Filtering
Results can be filtered by:
- `commodity`: Specific commodity type(s)
- `asset_type`: Specific asset type(s)

## Pattern Matching
Two types of pattern matching are supported:

1. Parameter-free matching:
   - `"ThermalPower"` matches any `ThermalPower{...}` type (i.e. no need to specify parameters inside `{}`)

2. Wildcards using "*":
   - `"ThermalPower*"` matches `ThermalPower{Fuel}`, `ThermalPowerCCS{Fuel}`, etc.
   - `"CO2*"` matches `CO2`, `CO2Captured`, etc.

# Arguments
- `file_path::AbstractString`: The path to the file where the results will be written
- `system::System`: The system containing the edges to analyze as well as the settings for the output
- `scaling::Float64`: The scaling factor for the results
- `drop_cols::Vector{<:AbstractString}`: Columns to drop from the DataFrame
- `commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The commodity to filter by
- `asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The asset type to filter by

# Returns
- `nothing`: The function returns nothing, but writes the results to the file

# Example
```julia
write_curtailment("curtailment.csv", system)
# Filter by commodity
write_curtailment("curtailment.csv", system, commodity="Electricity")
# Filter by commodity and asset type using parameter-free matching
write_curtailment("curtailment.csv", system, commodity="Electricity", asset_type="VRE")
# Filter by commodity and asset type using wildcard matching
write_curtailment("curtailment.csv", system, commodity="Electricity", asset_type="VRE*")
```
"""
function write_curtailment(
    file_path::AbstractString, 
    system::System; 
    scaling::Float64=1.0, 
    drop_cols::Vector{<:AbstractString}=String[],
    commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing,
    asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
)
    @info "Writing curtailment results to $file_path"

    # Get curtailment results and determine layout (wide or long)
    curtailment_results = get_optimal_curtailment(system; scaling, commodity, asset_type)
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
function write_curtailments(file_path::AbstractString, 
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
    get_optimal_curtailment(
        system::System; 
        scaling::Float64=1.0, 
        commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing, 
        asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
    )

Get the optimal curtailment values for all edges in a system.

Curtailment is the difference between available capacity and actual generation:
curtailment = availability(e,t) * capacity(e) - flow(e,t)

Curtailment is only calculated for edges with capacity constraints.

## Filtering
Results can be filtered by:
- `commodity`: Specific commodity type(s)
- `asset_type`: Specific asset type(s)

## Pattern Matching
Two types of pattern matching are supported:

1. Parameter-free matching:
   - `"ThermalPower"` matches any `ThermalPower{...}` type (i.e. no need to specify parameters inside `{}`)

2. Wildcards using "*":
   - `"ThermalPower*"` matches `ThermalPower{Fuel}`, `ThermalPowerCCS{Fuel}`, etc.
   - `"CO2*"` matches `CO2`, `CO2Captured`, etc.

# Arguments
- `system::System`: The system containing the all edges to output   
- `scaling::Float64`: The scaling factor for the results.
- `commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The commodity to filter by
- `asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The asset type to filter by

# Returns
- `DataFrame`: A dataframe containing the optimal curtailment values for all edges with capacity, with missing columns removed

# Example
```julia
get_optimal_curtailment(system)
# Filter by commodity
get_optimal_curtailment(system, commodity="Electricity")
# Filter by commodity and asset type using parameter-free matching
get_optimal_curtailment(system, commodity="Electricity", asset_type="VRE")
# Filter by commodity and asset type using wildcard matching
get_optimal_curtailment(system, commodity="Electricity", asset_type="VRE*")
```
"""
function get_optimal_curtailment(
    system::System; 
    scaling::Float64=1.0, 
    commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing,
    asset_type::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
)
    @debug " -- Getting optimal curtailment values for the system"
    edges, edge_asset_map = get_edges(system, return_ids_map=true)

    # filter edges by commodity
    if !isnothing(commodity)
        (commodity, missed_commodites) = search_commodities(commodity, string.(collect(Set(MacroEnergy.commodity_type.(edges)))))
        if !isempty(missed_commodites)
            @warn "Commodities not found: $(missed_commodites) when printing curtailment results"
        end
        filter_edges_by_commodity!(edges, commodity, edge_asset_map)
    end
    # filter edges by asset type
    if !isnothing(asset_type)
        (asset_type, missed_asset_type) = search_assets(asset_type, string.(unique(get_type(asset) for asset in values(edge_asset_map))))
        if !isempty(missed_asset_type)
            @warn "Asset type(s) not found: $(missed_asset_type) when printing curtailment results"
        end
        @debug("Writing curtailment results for asset type $asset_type")
        filter_edges_by_asset_type!(edges, asset_type, edge_asset_map)
    end
    
    # Filter to only edges with capacity (curtailment only makes sense for these)
    edges = filter(has_capacity, edges)
    
    if isempty(edges)
        @warn "No edges with capacity found after filtering"
        return DataFrame()
    end
    ecurtail = get_optimal_curtailment(edges, scaling, edge_asset_map)
    ecurtail[!, (!isa).(eachcol(ecurtail), Vector{Missing})] # remove missing columns
end

"""
    get_optimal_curtailment(asset::AbstractAsset, scaling::Float64=1.0)

Get the optimal curtailment values for all edges in an asset.

Curtailment is the difference between available capacity and actual generation:
curtailment = availability(e,t) * capacity(e) - flow(e,t)

Curtailment is only calculated for edges with capacity constraints.

# Arguments
- `asset::AbstractAsset`: The asset containing the edges to analyze
- `scaling::Float64`: The scaling factor for the results.

# Returns
- `DataFrame`: A dataframe containing the optimal curtailment values for all edges with capacity, with missing columns removed

# Example
```julia
asset = get_asset_by_id(system, :elec_SE)
get_optimal_curtailment(asset)
```
"""
function get_optimal_curtailment(asset::AbstractAsset; scaling::Float64=1.0)
    @debug " -- Getting optimal curtailment values for the asset $(id(asset))"
    edges, edge_asset_map = get_edges(asset, return_ids_map=true)
    # Filter to only edges with capacity
    edges = filter(has_capacity, edges)
    ecurtail = get_optimal_curtailment(edges, scaling, edge_asset_map)
    ecurtail[!, (!isa).(eachcol(ecurtail), Vector{Missing})] # remove missing columns
end

## Timeseries curtailment extraction functions ##
# The following functions are used to extract curtailment values after the model has been solved
# from a list of MacroObjects (e.g., edges) 
function get_optimal_curtailment(
    objs::Vector{<:AbstractEdge},
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    reduce(vcat, [get_optimal_curtailment(o, scaling, obj_asset_map) for o in objs])
end

function get_optimal_curtailment(
    obj::AbstractEdge,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
)
    time_axis = time_interval(obj)
    # Curtailment = available capacity - actual flow
    # Only makes sense for edges with capacity, but we check anyway
    if !has_capacity(obj)
        return DataFrame()
    end
    
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
            value = [max(0.0, availability(obj, t) * value(capacity(obj)) - value(flow(obj, t))) * scaling for t in time_axis]
        )
    else
        return DataFrame(
            case_name = fill(missing, length(time_axis)),
            commodity = fill(get_commodity_name(obj), length(time_axis)),
            node_in = fill(get_node_in(obj), length(time_axis)),
            node_out = fill(get_node_out(obj), length(time_axis)),
            resource_id = fill(isa(obj, Node) ? get_resource_id(obj) : get_resource_id(obj, obj_asset_map), length(time_axis)),
            component_id = fill(get_component_id(obj), length(time_axis)),
            resource_type = fill(isa(obj, Node) ? get_type(obj) : get_type(obj_asset_map[id(obj)]), length(time_axis)),
            component_type = fill(get_type(obj), length(time_axis)),
            variable = :curtailment,
            year = fill(missing, length(time_axis)),
            time = [t for t in time_axis],
            value = [max(0.0, availability(obj, t) * value(capacity(obj)) - value(flow(obj, t))) * scaling for t in time_axis]
        )
    end
end
