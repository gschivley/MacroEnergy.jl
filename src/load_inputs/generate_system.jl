###### ###### ###### ###### ###### ######
# Internal functions to handle loading the system
###### ###### ###### ###### ###### ######

function generate_system!(
    system::System,
    file_path::AbstractString;
    lazy_load::Bool = true,
)::nothing
    # Load the system data file
    @info("Generating system from $file_path")
    system_data = load_system_data(file_path, system.data_dirpath; lazy_load = lazy_load)
    generate_system!(system, system_data)
    return nothing
end

function generate_system!(system::System, system_data::AbstractDict{Symbol,Any})::Nothing
    @info("Generating system")
    start_time = time();
    # Configure the settings
    system.settings = configure_settings(system_data[:settings], system.data_dirpath)

    # Load the commodities
    system.commodities = load_commodities(system_data[:commodities], system.data_dirpath; write_subcommodities=system.settings.WriteSubcommodities)

    # Load the locations
    load_locations!(system, system.data_dirpath, system_data[:locations])

    # Load the time data
    system.time_data =
        load_time_data(system_data[:time_data], system.commodities, system.data_dirpath)

    # Load the nodes
    load!(system, system_data[:nodes])

    # Load the assets
    load!(system, system_data[:assets])

    # Load global constraints (optional)
    if haskey(system_data, :global_constraints)
        load_global_constraints!(system, system_data[:global_constraints])
    end

    @info("Done generating system. It took $(round(time() - start_time, digits=2)) seconds")
    return nothing
end

function generate_system!(
    periods::Vector{System},
    file_path::AbstractString;
    lazy_load::Bool = true,
)::Nothing
    # Load the system data file
    @info("Generating system from $file_path")
    system_data = load_system_data(file_path, system.data_dirpath; lazy_load = lazy_load)
    generate_system!(periods, system_data)
    return nothing
end

"""
    load_global_constraints!(system::System, data::AbstractDict{Symbol,Any})

Load system-level (global) constraints from a dictionary and add them to the system.
Each key in the dictionary is the name of a constraint type and each value is either
`true` (for constraints with no parameters) or a dictionary of keyword arguments.

# Arguments
- `system`: The `System` to add constraints to
- `data`: A dictionary mapping constraint type names to their configuration
"""
function load_global_constraints!(system::System, data::AbstractDict{Symbol,Any})
    constraint_library = constraint_types()
    for (name, config) in data
        name_sym = Symbol(name)
        if !haskey(constraint_library, name_sym)
            throw(ArgumentError("Unknown global constraint type: $name"))
        end
        ct_type = constraint_library[name_sym]
        if isa(config, Bool) && config == true
            push!(system.global_constraints, ct_type())
        elseif isa(config, AbstractDict)
            kwargs = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in config)
            push!(system.global_constraints, ct_type(; kwargs...))
        end
    end
    return nothing
end