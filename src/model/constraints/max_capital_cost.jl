Base.@kwdef mutable struct MaxCapitalCostConstraint <: PlanningConstraint
    value::Union{Missing,Float64} = missing
    constraint_dual::Union{Missing,Float64} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
    max_capital_cost::Float64 = Inf
end

@doc raw"""
    add_model_constraint!(ct::MaxCapitalCostConstraint, system::System, model::Model)

Add a constraint limiting total capital spending for new capacity in a given period.
The constraint sums the product of the investment cost and the new capacity for all
expandable edges and storages in the system and constrains the total to be at most
`ct.max_capital_cost`.

Therefore, the functional form of the constraint is:

```math
\begin{aligned}
    \sum_{y \in \mathcal{Y}} \text{investment\_cost}(y) \times \text{new\_capacity}(y) \leq \text{max\_capital\_cost}
\end{aligned}
```

where ``\mathcal{Y}`` is the set of all expandable edges and storages in the system.

!!! note "Units"
    The `max_capital_cost` should be in the same units as the product of
    `investment_cost` (cost per unit capacity) and `new_capacity` (capacity units).

!!! note "Setting up the constraint"
    To enable this constraint for a system period, add a `"global_constraints"` key to
    the system data with a `"MaxCapitalCostConstraint"` entry specifying the
    `"max_capital_cost"` value.

    ```json
    {
      "global_constraints": {
        "MaxCapitalCostConstraint": {
          "max_capital_cost": 1000000
        }
      }
    }
    ```
"""
function add_model_constraint!(ct::MaxCapitalCostConstraint, system::System, model::Model)
    capital_cost_expr = AffExpr(0.0)

    for a in system.assets
        for t in fieldnames(typeof(a))
            y = getfield(a, t)
            if isa(y, AbstractEdge) && has_capacity(y) && can_expand(y)
                add_to_expression!(capital_cost_expr, investment_cost(y), new_capacity(y))
            elseif isa(y, AbstractStorage) && can_expand(y)
                add_to_expression!(capital_cost_expr, investment_cost(y), new_capacity(y))
            end
        end
    end

    ct.constraint_ref = @constraint(model, capital_cost_expr <= ct.max_capital_cost)

    return nothing
end
