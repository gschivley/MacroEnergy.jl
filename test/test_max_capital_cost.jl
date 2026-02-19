module TestMaxCapitalCostConstraint

using Test
using HiGHS
using JuMP
import MacroEnergy
import MacroEnergy:
    MaxCapitalCostConstraint,
    PlanningConstraint,
    AbstractTypeConstraint,
    System,
    Case,
    load_case,
    generate_model,
    create_optimizer,
    optimize!,
    objective_value,
    termination_status,
    constraint_types,
    can_expand,
    has_capacity,
    investment_cost,
    new_capacity,
    AbstractEdge,
    AbstractStorage

include("utilities.jl")

const test_path = joinpath(@__DIR__, "test_small_case")
const optim = HiGHS.Optimizer

@testset "MaxCapitalCostConstraint Tests" begin

    @testset "Struct creation" begin
        # Default constructor
        ct = MaxCapitalCostConstraint()
        @test ct.max_capital_cost == Inf
        @test ismissing(ct.constraint_ref)
        @test ismissing(ct.constraint_dual)
        @test ct isa PlanningConstraint
        @test ct isa AbstractTypeConstraint

        # Constructor with value
        ct2 = MaxCapitalCostConstraint(max_capital_cost = 1_000_000.0)
        @test ct2.max_capital_cost == 1_000_000.0

        # Constructor with integer (tests implicit Float64 conversion)
        ct3 = MaxCapitalCostConstraint(max_capital_cost = 500_000)
        @test ct3.max_capital_cost == 500_000.0
        @test ct3.max_capital_cost isa Float64
    end

    @testset "Registered in constraint_types()" begin
        cts = constraint_types()
        @test haskey(cts, :MaxCapitalCostConstraint)
        @test cts[:MaxCapitalCostConstraint] == MaxCapitalCostConstraint
    end

    @testset "load_global_constraints! from dict" begin
        system = MacroEnergy.empty_system("/tmp")
        @test isempty(system.global_constraints)

        # Load a MaxCapitalCostConstraint via dict
        data = Dict{Symbol,Any}(
            :MaxCapitalCostConstraint => Dict{Symbol,Any}(:max_capital_cost => 999_999.0)
        )
        MacroEnergy.load_global_constraints!(system, data)
        @test length(system.global_constraints) == 1
        @test system.global_constraints[1] isa MaxCapitalCostConstraint
        @test system.global_constraints[1].max_capital_cost == 999_999.0
    end

    @testset "load_global_constraints! with boolean flag" begin
        system = MacroEnergy.empty_system("/tmp")
        data = Dict{Symbol,Any}(:MaxCapitalCostConstraint => true)
        MacroEnergy.load_global_constraints!(system, data)
        @test length(system.global_constraints) == 1
        @test system.global_constraints[1] isa MaxCapitalCostConstraint
        @test system.global_constraints[1].max_capital_cost == Inf  # default
    end

    @testset "load_global_constraints! rejects unknown constraint" begin
        system = MacroEnergy.empty_system("/tmp")
        data = Dict{Symbol,Any}(:UnknownConstraintXYZ => true)
        @test_throws ArgumentError MacroEnergy.load_global_constraints!(system, data)
    end

    @testset "Constraint applied in optimization" begin
        # Load the small test case
        case = load_case(test_path)
        system = case.systems[1]

        # Compute total possible capital spending without the constraint
        optimizer = create_optimizer(optim)
        model_unconstrained = generate_model(case, optimizer)
        optimize!(model_unconstrained)
        @test termination_status(model_unconstrained) == MOI.OPTIMAL

        # Calculate the unconstrained capital spending
        unconstrained_capex = sum(
            investment_cost(y) * JuMP.value(new_capacity(y))
            for a in system.assets
            for t in fieldnames(typeof(a))
            for y in [getfield(a, t)]
            if (isa(y, AbstractEdge) && has_capacity(y) && can_expand(y)) ||
               (isa(y, AbstractStorage) && can_expand(y))
        )

        # Add a tight capital spending constraint (60% of unconstrained)
        tight_budget = unconstrained_capex * 0.6
        push!(system.global_constraints, MaxCapitalCostConstraint(max_capital_cost = tight_budget))

        # Reload case with constraint applied
        case2 = load_case(test_path)
        push!(case2.systems[1].global_constraints, MaxCapitalCostConstraint(max_capital_cost = tight_budget))

        optimizer2 = create_optimizer(optim)
        model_constrained = generate_model(case2, optimizer2)
        optimize!(model_constrained)
        @test termination_status(model_constrained) == MOI.OPTIMAL

        # The constrained objective should be >= unconstrained objective
        @test objective_value(model_constrained) >= objective_value(model_unconstrained) - 1e-4

        # Verify the capital spending is within budget
        system2 = case2.systems[1]
        constrained_capex = sum(
            investment_cost(y) * JuMP.value(new_capacity(y))
            for a in system2.assets
            for t in fieldnames(typeof(a))
            for y in [getfield(a, t)]
            if (isa(y, AbstractEdge) && has_capacity(y) && can_expand(y)) ||
               (isa(y, AbstractStorage) && can_expand(y))
        )
        @test constrained_capex <= tight_budget + 1e-4
    end

end # @testset

end # module
