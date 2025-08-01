# Fitting module - Contains all ODE fitting and comparison functions
module Fitting

using StatsBase
using CSV
using DataFrames
using DifferentialEquations
using LsqFit
using RecursiveArrayTools
using DiffEqParamEstim
using Optimization
using ForwardDiff
using OptimizationOptimJL
using OptimizationBBO
using BlackBoxOptim

# Import models from Models module
using ..Models

export setUpProblem, calculate_bic, pQuickStat, run_single_fit, 
       compare_models, compare_datasets, compare_models_dict, fit_three_datasets

"""
    setUpProblem(model, xdata, ydata, solver, u0, p, tspan, bounds)

Sets up and solves an ODE fitting problem using BlackBoxOptim.
Returns optimized parameters, solution, and the problem object.
"""
function setUpProblem(model, x, y, solver, u0, p0, tspan, bounds)
    prob = ODEProblem(model, u0, tspan, p0)
    solve(prob, solver, saveat=x, reltol=1e-16, abstol=1e-16)

    loss = build_loss_objective(
        prob, solver,
        L2Loss(x, y),
        Optimization.AutoForwardDiff();
        maxiters=10_000, verbose=false
    )

    result = bboptimize(
        loss;
        SearchRange = collect(zip(first.(bounds), last.(bounds))),
        Method      = :de_rand_1_bin,
        MaxTime     = 100.0,
        TraceMode   = :silent
    )

    p̂      = best_candidate(result)
    prob̂   = ODEProblem(model, [y[1]], tspan, p̂)
    x_dense = range(x[1], x[end], length=1000)
    sol̂    = solve(prob̂, solver, reltol=1e-12, abstol=1e-12, saveat=x_dense)

    return p̂, sol̂, prob̂
end

"""
    calculate_bic(prob, xdata, ydata, solver, params)

Calculates the Bayesian Information Criterion (BIC) and Sum of Squared Residuals (SSR) for a solved ODE model.
"""
function calculate_bic(prob, x, y, solver, p)
    sol = solve(prob, solver, reltol=1e-15, abstol=1e-15, saveat=x)
    resid = y .- getindex.(sol.u, 1)
    ssr   = sum(resid .^ 2)
    k     = length(p)
    n     = length(x)
    bic   = n * log(ssr / n) + k * log(n)
    bic, ssr
end

"""
    pQuickStat(x, y, optimized_params, optimized_sol, optimized_prob, bic, ssr)

Prints model parameters, BIC, and SSR.
"""
function pQuickStat(x, y, p, sol, prob, bic, ssr)
    println("→ Optimized params: ", p)
    println("→ SSR: ", ssr)
    println("→ BIC: ", bic)
end

function run_single_fit(
    x::Vector{<:Real},
    y::Vector{<:Real},
    p0::Vector{<:Real};
    model         = Models.logistic_growth!,
    fixed_params  = nothing,
    solver        = Rodas5(),
    bounds        = nothing,
    show_stats::Bool = true
)
    # Handle fixed parameters
    if fixed_params !== nothing
        original_model = model
        n_total_params = length(p0) + length(fixed_params)
        
        # Create a new model that reconstructs full parameter vector
        model = function(du, u, p_free, t)
            # Reconstruct full parameter vector by inserting free params and fixed params
            p_full = zeros(n_total_params)
            free_idx = 1
            for i in 1:n_total_params
                if haskey(fixed_params, i)
                    p_full[i] = fixed_params[i]
                else
                    p_full[i] = p_free[free_idx]
                    free_idx += 1
                end
            end
            original_model(du, u, p_full, t)
        end
        
        # Remove fixed parameters from p0 and bounds
        free_indices = [i for i in 1:length(p0) if !haskey(fixed_params, i)]
        p0 = p0[free_indices]
        if bounds !== nothing
            bounds = bounds[free_indices]
        end
    end

    nparams = length(p0)
    bounds === nothing && (bounds = [(0.0, Inf) for _ in 1:nparams])

    x      = Float64.(x)
    y      = Float64.(y)
    tspan  = (x[1], x[end])
    u0     = [y[1]]

    p̂, sol̂, prob̂ = setUpProblem(model, x, y, solver, u0, p0, tspan, bounds)
    bic, ssr       = calculate_bic(prob̂, x, y, solver, p̂)
    show_stats && pQuickStat(x, y, p̂, sol̂, prob̂, bic, ssr)

    return (params = p̂, bic = bic, ssr = ssr, solution = sol̂)
end

# ────────────────────────────────────────────────────────────────────────────
# 1. Compare two models on the same dataset
# ────────────────────────────────────────────────────────────────────────────
"""
compare_models(
    x::Vector{<:Real},
    y::Vector{<:Real},
    name1::String, model1::Function, p0_1::Vector{<:Real},
    name2::String, model2::Function, p0_2::Vector{<:Real};
    solver               = Rodas5(),
    bounds1              = nothing,
    bounds2              = nothing,
    fixed_params1        = nothing,
    fixed_params2        = nothing,
    show_stats::Bool     = false,
    output_csv::String   = "model_comparison.csv"
)

Fits two candidate models to the same dataset via `run_single_fit`,
prints parameter/BIC/SSR, and writes a CSV summary.
"""
function compare_models(
    x::Vector{<:Real},
    y::Vector{<:Real},
    name1::String, model1::Function, p0_1::Vector{<:Real},
    name2::String, model2::Function, p0_2::Vector{<:Real};
    solver             = Rodas5(),
    bounds1            = nothing,
    bounds2            = nothing,
    fixed_params1      = nothing,
    fixed_params2      = nothing,
    show_stats::Bool   = false,
    output_csv::String = "model_comparison.csv"
)
    # Fit model 1
    fit1 = run_single_fit(
        x, y, p0_1;
        model        = model1,
        fixed_params = fixed_params1,
        solver       = solver,
        bounds       = bounds1,
        show_stats   = show_stats
    )

    # Fit model 2
    fit2 = run_single_fit(
        x, y, p0_2;
        model        = model2,
        fixed_params = fixed_params2,
        solver       = solver,
        bounds       = bounds2,
        show_stats   = show_stats
    )

    # Convert to Float64 for calculations
    x, y = Float64.(x), Float64.(y)

    # Print summary
    println("=== $name1 ===")
    println("Params: $(fit1.params), BIC: $(fit1.bic), SSR: $(fit1.ssr)")
    println("=== $name2 ===")
    println("Params: $(fit2.params), BIC: $(fit2.bic), SSR: $(fit2.ssr)")

    # Save CSV
    df_out = DataFrame(
        Model  = [name1, name2],
        Params = [string(fit1.params), string(fit2.params)],
        BIC    = [fit1.bic, fit2.bic],
        SSR    = [fit1.ssr, fit2.ssr]
    )
    CSV.write(output_csv, df_out)
    println("Results saved to $output_csv")
    
    # Determine best model
    best_model = fit1.bic <= fit2.bic ? 
                 (name=name1, params=fit1.params, bic=fit1.bic, ssr=fit1.ssr, solution=fit1.solution) :
                 (name=name2, params=fit2.params, bic=fit2.bic, ssr=fit2.ssr, solution=fit2.solution)
    
    # Return comparison results
    return (
        model1 = (name=name1, params=fit1.params, bic=fit1.bic, ssr=fit1.ssr, solution=fit1.solution),
        model2 = (name=name2, params=fit2.params, bic=fit2.bic, ssr=fit2.ssr, solution=fit2.solution),
        best_model = best_model
    )
end

# ────────────────────────────────────────────────────────────────────────────
# 2. Compare same or different models across two datasets
# ────────────────────────────────────────────────────────────────────────────
"""
compare_datasets(
    x1::Vector{<:Real}, y1::Vector{<:Real}, name1::String, model1::Function, p0_1::Vector{<:Real},
    x2::Vector{<:Real}, y2::Vector{<:Real}, name2::String, model2::Function, p0_2::Vector{<:Real};
    solver               = Rodas5(),
    bounds1              = nothing,
    bounds2              = nothing,
    fixed_params1        = nothing,
    fixed_params2        = nothing,
    show_stats::Bool     = false,
    output_csv::String   = "dataset_comparison.csv"
)

Fits a model to two different datasets via `run_single_fit`,
prints stats, and writes a CSV summary.
"""
function compare_datasets(
    x1::Vector{<:Real}, y1::Vector{<:Real}, name1::String, model1::Function, p0_1::Vector{<:Real},
    x2::Vector{<:Real}, y2::Vector{<:Real}, name2::String, model2::Function, p0_2::Vector{<:Real};
    solver             = Rodas5(),
    bounds1            = nothing,
    bounds2            = nothing,
    fixed_params1      = nothing,
    fixed_params2      = nothing,
    show_stats::Bool   = false,
    output_csv::String = "dataset_comparison.csv"
)
    # Fit first dataset
    fit1 = run_single_fit(
        x1, y1, p0_1;
        model        = model1,
        fixed_params = fixed_params1,
        solver       = solver,
        bounds       = bounds1,
        show_stats   = show_stats
    )

    # Fit second dataset
    fit2 = run_single_fit(
        x2, y2, p0_2;
        model        = model2,
        fixed_params = fixed_params2,
        solver       = solver,
        bounds       = bounds2,
        show_stats   = show_stats
    )

    # Convert to Float64 for calculations
    x1, y1 = Float64.(x1), Float64.(y1)
    x2, y2 = Float64.(x2), Float64.(y2)

    # Print summary
    println("=== $name1 ===")
    println("Params: $(fit1.params), BIC: $(fit1.bic), SSR: $(fit1.ssr)")
    println("=== $name2 ===")
    println("Params: $(fit2.params), BIC: $(fit2.bic), SSR: $(fit2.ssr)")

    # Save CSV
    df_out = DataFrame(
        Dataset = [name1, name2],
        Params  = [string(fit1.params), string(fit2.params)],
        BIC     = [fit1.bic, fit2.bic],
        SSR     = [fit1.ssr, fit2.ssr]
    )
    CSV.write(output_csv, df_out)
    println("Results saved to $output_csv")
end

"""
compare_models_dict(
    x::Vector{<:Real},
    y::Vector{<:Real},
    specs::Dict{String,<:NamedTuple};
    default_solver        = Rodas5(),
    show_stats::Bool      = false,
    output_csv::String    = "all_models_comparison.csv"
)

Fits each model in `specs` to the x,y data, allowing each spec to override solver,
prints a summary table, and writes results to CSV.

Each `specs[name]` should be a NamedTuple with fields:
  • model::Function
  • p0::Vector{<:Real}
  • bounds::Vector{Tuple{<:Real,<:Real}}
  • fixed_params::Union{Nothing,Vector{<:Real}}
  • (optional) solver::Any  # e.g. Rodas5() or Tsit5()
"""
function compare_models_dict(
    x::Vector{<:Real},
    y::Vector{<:Real},
    specs::Dict{String,<:NamedTuple};
    default_solver        = Rodas5(),
    show_stats::Bool      = false,
    output_csv::String    = "all_models_comparison.csv"
)
    fits = Dict{String,Any}()
    results = NamedTuple[]
    # Fit each model
    for (name, spec) in specs
        solver_i = haskey(spec, :solver) ? spec.solver : default_solver
        fit = run_single_fit(
            x, y, spec.p0;
            model        = spec.model,
            fixed_params = spec.fixed_params,
            solver       = solver_i,
            bounds       = spec.bounds,
            show_stats   = show_stats
        )
        fits[name] = fit
        push!(results, (
            Model  = name,
            Params = fit.params,
            BIC    = fit.bic,
            SSR    = fit.ssr
        ))
    end

    # Summary DataFrame
    df_summary = DataFrame(
        Model  = [r.Model for r in results],
        Params = [string(r.Params) for r in results],
        BIC    = [r.BIC for r in results],
        SSR    = [r.SSR for r in results]
    )
    # Print BIC table
    println("
BIC Summary:")
    display(df_summary[:, [:Model, :BIC]])

    # Save summary CSV
    CSV.write(output_csv, df_summary)
    println("Summary saved to $output_csv")

    # Collect raw predictions
    pred_rows = NamedTuple[]
    for (name, fit) in pairs(fits)
        for (t, u) in zip(fit.solution.t, fit.solution.u)
            push!(pred_rows, (Model=name, Time=t, Prediction=u[1]))
        end
    end
    df_preds = DataFrame(pred_rows)
    preds_csv = replace(output_csv, r"\.csv$" => "_predictions.csv")
    CSV.write(preds_csv, df_preds)
    println("Predictions saved to $preds_csv")

    return fits
end

"""
fit_three_datasets(
    x1::Vector{<:Real}, y1::Vector{<:Real}, name1::String,
    x2::Vector{<:Real}, y2::Vector{<:Real}, name2::String,
    x3::Vector{<:Real}, y3::Vector{<:Real}, name3::String,
    p0::Vector{<:Real};
    model                = Models.logistic_growth!,
    fixed_params         = nothing,
    solver               = Rodas5(),
    bounds               = nothing,
    show_stats::Bool     = false,
    output_csv::String   = "three_datasets_comparison.csv"
)

Fits the same ODE model to three different datasets with identical initial conditions,
prints statistics, and saves results to CSV.

This is essentially a wrapper around `run_single_fit` that handles three datasets
with the same model and parameters but allows for different data.
"""
function fit_three_datasets(
    x1::Vector{<:Real}, y1::Vector{<:Real}, name1::String,
    x2::Vector{<:Real}, y2::Vector{<:Real}, name2::String,
    x3::Vector{<:Real}, y3::Vector{<:Real}, name3::String,
    p0::Vector{<:Real};
    model                = Models.logistic_growth!,
    fixed_params         = nothing,
    solver               = Rodas5(),
    bounds               = nothing,
    show_stats::Bool     = false,
    output_csv::String   = "three_datasets_comparison.csv"
)
    # Fit each dataset individually
    fit1 = run_single_fit(
        x1, y1, p0;
        model        = model,
        fixed_params = fixed_params,
        solver       = solver,
        bounds       = bounds,
        show_stats   = show_stats
    )

    fit2 = run_single_fit(
        x2, y2, p0;
        model        = model,
        fixed_params = fixed_params,
        solver       = solver,
        bounds       = bounds,
        show_stats   = show_stats
    )

    fit3 = run_single_fit(
        x3, y3, p0;
        model        = model,
        fixed_params = fixed_params,
        solver       = solver,
        bounds       = bounds,
        show_stats   = show_stats
    )

    # Convert to Float64 for calculations
    x1, y1 = Float64.(x1), Float64.(y1)
    x2, y2 = Float64.(x2), Float64.(y2)
    x3, y3 = Float64.(x3), Float64.(y3)

    # Print summary statistics
    println("=== $name1 ===")
    println("Params: $(fit1.params), BIC: $(fit1.bic), SSR: $(fit1.ssr)")
    println("=== $name2 ===")
    println("Params: $(fit2.params), BIC: $(fit2.bic), SSR: $(fit2.ssr)")
    println("=== $name3 ===")
    println("Params: $(fit3.params), BIC: $(fit3.bic), SSR: $(fit3.ssr)")

    # Save results to CSV
    df_out = DataFrame(
        Dataset = [name1, name2, name3],
        Params  = [string(fit1.params), string(fit2.params), string(fit3.params)],
        BIC     = [fit1.bic, fit2.bic, fit3.bic],
        SSR     = [fit1.ssr, fit2.ssr, fit3.ssr]
    )
    CSV.write(output_csv, df_out)
    println("Results saved to $output_csv")

    # Return all fit results
    return (fit1 = fit1, fit2 = fit2, fit3 = fit3)
end

"""
fit_three_datasets(
    x_datasets::Vector{Vector{<:Real}},
    y_datasets::Vector{Vector{<:Real}};
    p0::Vector{<:Real}     = [0.1, 100.0],
    model                  = Models.logistic_growth!,
    fixed_params           = nothing,
    solver                 = Rodas5(),
    bounds                 = nothing
)

Fits the same ODE model to multiple datasets provided as vectors of vectors.
Returns individual fits and summary statistics.

This version accepts datasets as vectors for convenience when working with 
programmatically generated data.
"""
function fit_three_datasets(
    x_datasets::Vector{Vector{<:Real}},
    y_datasets::Vector{Vector{<:Real}};
    p0::Vector{<:Real}     = [0.1, 100.0],
    model                  = Models.logistic_growth!,
    fixed_params           = nothing,
    solver                 = Rodas5(),
    bounds                 = nothing
)
    n_datasets = length(x_datasets)
    @assert length(y_datasets) == n_datasets "Number of x and y datasets must match"
    
    # Fit each dataset
    individual_fits = []
    for i in 1:n_datasets
        try
            fit_result = run_single_fit(
                x_datasets[i], y_datasets[i], p0;
                model        = model,
                fixed_params = fixed_params,
                solver       = solver,
                bounds       = bounds,
                show_stats   = false
            )
            
            push!(individual_fits, (dataset = i, fit_result = fit_result))
        catch e
            println("Warning: Failed to fit dataset $i: $e")
            push!(individual_fits, (dataset = i, fit_result = nothing))
        end
    end
    
    # Calculate summary statistics
    successful_fits = filter(f -> f.fit_result !== nothing, individual_fits)
    
    if length(successful_fits) > 0
        all_params = [f.fit_result.params for f in successful_fits]
        mean_params = [mean([p[i] for p in all_params]) for i in 1:length(all_params[1])]
        std_params = [std([p[i] for p in all_params]) for i in 1:length(all_params[1])]
        mean_ssr = mean([f.fit_result.ssr for f in successful_fits])
        
        summary = (
            mean_params = mean_params,
            std_params = std_params,
            mean_ssr = mean_ssr,
            n_successful = length(successful_fits),
            n_total = n_datasets
        )
    else
        summary = (
            mean_params = Float64[],
            std_params = Float64[],
            mean_ssr = Inf,
            n_successful = 0,
            n_total = n_datasets
        )
    end
    
    return (individual_fits = individual_fits, summary = summary)
end

end # module Fitting
