"""
Curtailment outputs - everything related to curtailment (non-served demand) data extraction and output.
"""

## Write curtailment outputs ##
# This is the main function to write the curtailment outputs to a file.

"""
    write_curtailment(
        file_path::AbstractString, 
        system::System; 
        scaling::Float64=1.0, 
        drop_cols::Vector{<:AbstractString}=String[],
        commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
    )

Write the optimal curtailment (non-served demand) results for the system to a file.
The extension of the file determines the format of the file.

## Filtering
Results can be filtered by:
- `commodity`: Specific commodity type(s)

## Pattern Matching
Two types of pattern matching are supported:

1. Parameter-free matching:
   - `"Electricity"` matches `Electricity` commodity

2. Wildcards using "*":
   - `"CO2*"` matches `CO2`, `CO2Captured`, etc.

# Arguments
- `file_path::AbstractString`: The path to the file where the results will be written
- `system::System`: The system containing the nodes to analyze as well as the settings for the output
- `scaling::Float64`: The scaling factor for the results
- `drop_cols::Vector{<:AbstractString}`: Columns to drop from the DataFrame
- `commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The commodity to filter by

# Returns
- `nothing`: The function returns nothing, but writes the results to the file

# Example
```julia
write_curtailment("curtailment.csv", system)
# Filter by commodity
write_curtailment("curtailment.csv", system, commodity="Electricity")
# Filter by multiple commodities
write_curtailment("curtailment.csv", system, commodity=["Electricity", "Hydrogen"])
```
"""
function write_curtailment(
    file_path::AbstractString, 
    system::System; 
    scaling::Float64=1.0, 
    drop_cols::Vector{<:AbstractString}=String[],
    commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
)
    @info "Writing curtailment results to $file_path"

    # Get curtailment results and determine layout (wide or long)
    curtailment_results = get_optimal_curtailment(system; scaling, commodity)
    
    if isempty(curtailment_results)
        @debug "No curtailment data to write"
        return nothing
    end
    
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
    
    if isempty(curtailment_results)
        @debug "No curtailment data to write"
        return nothing
    end
    
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
        commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
    )

Get the optimal curtailment (non-served demand) values for all nodes in a system.

## Filtering
Results can be filtered by:
- `commodity`: Specific commodity type(s)

## Pattern Matching
Two types of pattern matching are supported:

1. Parameter-free matching:
   - `"Electricity"` matches `Electricity` commodity

2. Wildcards using "*":
   - `"CO2*"` matches `CO2`, `CO2Captured`, etc.

# Arguments
- `system::System`: The system containing all nodes to output   
- `scaling::Float64`: The scaling factor for the results.
- `commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}`: The commodity to filter by

# Returns
- `DataFrame`: A dataframe containing the optimal curtailment values for all nodes, with missing columns removed

# Example
```julia
get_optimal_curtailment(system)
# Filter by commodity
get_optimal_curtailment(system, commodity="Electricity")
```
"""
function get_optimal_curtailment(
    system::System; 
    scaling::Float64=1.0, 
    commodity::Union{AbstractString,Vector{<:AbstractString},Nothing}=nothing
)
    @debug " -- Getting optimal curtailment values for the system"
    nodes = get_nodes(system)
    
    # Filter to only nodes with non-served demand variables
    nodes_with_nsd = filter(n -> n isa Node && !isempty(non_served_demand(n)), nodes)
    
    if isempty(nodes_with_nsd)
        @debug "No nodes with non-served demand found"
        return DataFrame()
    end
    
    # Create a node asset map for resource_id lookup
    node_asset_map = Dict{Symbol,Base.RefValue{Node}}()
    for node in nodes_with_nsd
        node_asset_map[id(node)] = Ref(node)
    end
    
    # Filter nodes by commodity
    if !isnothing(commodity)
        (commodity, missed_commodities) = search_commodities(commodity, string.(collect(Set(MacroEnergy.commodity_type.(nodes_with_nsd)))))
        if !isempty(missed_commodities)
            @warn "Commodities not found: $(missed_commodities) when printing curtailment results"
        end
        filter!(n -> string(MacroEnergy.commodity_type(n)) in commodity, nodes_with_nsd)
    end
    
    if isempty(nodes_with_nsd)
        @warn "No nodes found after filtering"
        return DataFrame()
    end
    
    curtailment = get_optimal_curtailment(nodes_with_nsd, scaling, node_asset_map)
    curtailment[!, (!isa).(eachcol(curtailment), Vector{Missing})] # remove missing columns
end

"""
    get_optimal_curtailment(asset::AbstractAsset, scaling::Float64=1.0)

Get the optimal curtailment values for nodes associated with an asset.

Note: Nodes are system-level entities, not asset components. This function is 
provided for API consistency but will return an empty DataFrame since assets
do not directly contain nodes. Use `get_optimal_curtailment(system)` instead.

# Arguments
- `asset::AbstractAsset`: The asset (for API consistency)
- `scaling::Float64`: The scaling factor for the results.

# Returns
- `DataFrame`: An empty dataframe since assets do not contain nodes

# Example
```julia
asset = get_asset_by_id(system, :elec_SE)
get_optimal_curtailment(asset)  # Returns empty DataFrame
```
"""
function get_optimal_curtailment(asset::AbstractAsset; scaling::Float64=1.0)
    @debug " -- Assets do not contain nodes; returning empty curtailment DataFrame"
    return DataFrame()
end

## Timeseries curtailment extraction functions ##
# The following functions are used to extract curtailment values after the model has been solved
# from a list of nodes with non-served demand variables
function get_optimal_curtailment(
    nodes::Vector{<:Node},
    scaling::Float64=1.0,
    node_asset_map::Dict{Symbol,Base.RefValue{<:Node}}=Dict{Symbol,Base.RefValue{<:Node}}()
)
    reduce(vcat, [get_optimal_curtailment(n, scaling, node_asset_map) for n in nodes])
end

function get_optimal_curtailment(
    node::Node,
    scaling::Float64=1.0,
    node_asset_map::Dict{Symbol,Base.RefValue{<:Node}}=Dict{Symbol,Base.RefValue{<:Node}}()
)
    # Return empty DataFrame if node has no non-served demand
    if isempty(non_served_demand(node))
        return DataFrame()
    end
    
    time_axis = time_interval(node)
    segments = segments_non_served_demand(node)
    
    # Create a row for each segment and timestep
    num_rows = length(segments) * length(time_axis)
    
    # Pre-allocate arrays for efficiency
    segment_vec = Vector{Int64}(undef, num_rows)
    time_vec = Vector{Int64}(undef, num_rows)
    value_vec = Vector{Float64}(undef, num_rows)
    
    idx = 1
    for s in segments
        for t in time_axis
            segment_vec[idx] = s
            time_vec[idx] = t
            value_vec[idx] = value(non_served_demand(node, s, t)) * scaling
            idx += 1
        end
    end
    
    return DataFrame(
        case_name = fill(missing, num_rows),
        commodity = fill(get_commodity_name(node), num_rows),
        zone = fill(get_zone_name(node), num_rows),
        resource_id = fill(id(node), num_rows),
        component_id = fill(get_component_id(node), num_rows),
        resource_type = fill(get_type(node), num_rows),
        component_type = fill(get_type(node), num_rows),
        variable = fill(:curtailment, num_rows),
        segment = segment_vec,
        year = fill(missing, num_rows),
        time = time_vec,
        value = value_vec
    )
end
