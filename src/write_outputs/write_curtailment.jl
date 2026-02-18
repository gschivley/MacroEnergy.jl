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
        drop_cols::Vector{<:AbstractString}=String[]
    )

Write the optimal curtailment (non-served demand) results for the system to a file.
The extension of the file determines the format of the file.

# Arguments
- `file_path::AbstractString`: The path to the file where the results will be written
- `system::System`: The system containing the nodes to analyze as well as the settings for the output
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
    
    # Check if there are any curtailment results to write
    if isempty(curtailment_results)
        @info "No curtailment variables found in the system"
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
    
    # Check if there are any curtailment results to write
    if isempty(curtailment_results)
        @info "No curtailment variables found in the subproblems"
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
    get_optimal_curtailment(system::System; scaling::Float64=1.0)

Get the optimal curtailment (non-served demand) values for all nodes in a system.

# Arguments
- `system::System`: The system containing the all nodes to output   
- `scaling::Float64`: The scaling factor for the results.

# Returns
- `DataFrame`: A dataframe containing the optimal curtailment values for all nodes with non-served demand variables, with missing columns removed

# Example
```julia
get_optimal_curtailment(system)
```
"""
function get_optimal_curtailment(system::System; scaling::Float64=1.0)
    @debug " -- Getting optimal curtailment values for the system"
    nodes = get_nodes(system)
    curtailment_df = get_optimal_curtailment(nodes, scaling)
    
    # Return empty DataFrame if no curtailment found
    if isempty(curtailment_df)
        return DataFrame()
    end
    
    curtailment_df[!, (!isa).(eachcol(curtailment_df), Vector{Missing})] # remove missing columns
end

## Timeseries curtailment extraction functions ##
# The following functions are used to extract curtailment values after the model has been solved
# from a list of Nodes (locations that contain nodes)
function get_optimal_curtailment(
    locations::Vector{Union{Node, Location}},
    scaling::Float64=1.0
)
    # Collect all nodes from locations
    all_nodes = Node[]
    for loc in locations
        if isa(loc, Node)
            push!(all_nodes, loc)
        elseif isa(loc, Location)
            # Get all nodes from the location's dictionary
            for node in values(loc.nodes)
                push!(all_nodes, node)
            end
        end
    end
    
    # Filter nodes that have non-served demand variables
    nodes_with_nsd = filter(n -> !isempty(non_served_demand(n)), all_nodes)
    
    if isempty(nodes_with_nsd)
        return DataFrame()
    end
    
    reduce(vcat, [get_optimal_curtailment(n, scaling) for n in nodes_with_nsd])
end

function get_optimal_curtailment(
    node::Node,
    scaling::Float64=1.0
)
    # Check if node has non-served demand variable
    if isempty(non_served_demand(node))
        return DataFrame()
    end
    
    time_axis = time_interval(node)
    num_segments = length(segments_non_served_demand(node))
    total_rows = num_segments * length(time_axis)
    
    return DataFrame(
        case_name = fill(missing, total_rows),
        commodity = fill(get_commodity_name(node), total_rows),
        zone = fill(get_zone_name(node), total_rows),
        resource_id = fill(get_component_id(node), total_rows),
        component_id = fill(get_component_id(node), total_rows),
        resource_type = fill(get_type(node), total_rows),
        component_type = fill(get_type(node), total_rows),
        variable = :non_served_demand,
        year = fill(missing, total_rows),
        segment = [s for s in segments_non_served_demand(node) for t in time_axis],
        time = [t for s in segments_non_served_demand(node) for t in time_axis],
        value = [value(non_served_demand(node, s, t)) * scaling for s in segments_non_served_demand(node) for t in time_axis]
    )
end
