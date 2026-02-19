# Outputs

Macro writes the following output files to the `results` directory (or `results_period_<N>` for multi-period models):

| File | Description |
|------|-------------|
| `capacity.csv` | Final, new, retired, and existing capacity for each asset/edge |
| `costs.csv` | Fixed, variable, and total discounted system costs |
| `undiscounted_costs.csv` | Undiscounted system costs |
| `flows.csv` | Flow for each commodity through each edge at each timestep |
| `curtailment.csv` | VRE curtailment (potential minus actual generation) at each timestep |

## Curtailment

The `curtailment.csv` file contains the curtailment for each VRE asset at each timestep.
Curtailment is the difference between potential generation (availability × capacity) and
actual generation (flow):

```math
\text{curtailment}(e, t) = \max(0, \text{availability}(e, t) \times \text{capacity}(e) - \text{flow}(e, t))
```

VRE resources may be dispatched at less than their potential generation due to grid constraints
such as transmission limits or oversupply of electricity.

For more details on writing results, see the Writing Results user guide.
