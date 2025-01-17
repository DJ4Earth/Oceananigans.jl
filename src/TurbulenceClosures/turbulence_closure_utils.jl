using Oceananigans.Operators

tracer_diffusivities(tracers, κ::Union{Number, Function}) = with_tracers(tracers, NamedTuple(), (tracers, init) -> κ)
tracer_diffusivities(tracers, ::Nothing) = nothing

function tracer_diffusivities(tracers, κ::NamedTuple)

    all(name ∈ propertynames(κ) for name in tracers) ||
        throw(ArgumentError("Tracer diffusivities or diffusivity parameters must either be a constants
                            or a `NamedTuple` with a value for every tracer!"))

    return κ
end

convert_diffusivity(FT, κ::Number; kw...) = convert(FT, κ)

function convert_diffusivity(FT, κ; discrete_form=false, loc=(nothing, nothing, nothing), parameters=nothing)
    discrete_form && return DiscreteDiffusionFunction(κ; loc, parameters)
    return κ
end
    
function convert_diffusivity(FT, κ::NamedTuple; discrete_form=false, loc=(nothing, nothing, nothing), parameters=nothing)
    κ_names = propertynames(κ)
    return NamedTuple{κ_names}(Tuple(convert_diffusivity(FT, κi; discrete_form, loc, parameters) for κi in κ))
end

@inline geo_mean_Δᶠ(i, j, k, grid::AbstractGrid) =
    cbrt(Δxᶜᶜᶜ(i, j, k, grid) * Δyᶜᶜᶜ(i, j, k, grid) * Δzᶜᶜᶜ(i, j, k, grid))

@inline cal_νᶜᶜᶜ(i, j, k, grid, closure, buoyancy, U, C) = zero(grid)
@inline cal_κᶜᶜᶜ(i, j, k, grid, closure, c, tracer_index, U) = zero(grid)

@kernel function calculate_nonlinear_viscosity!(νₑ, grid, closure, buoyancy, U, C)
    i, j, k = @index(Global, NTuple)
    @inbounds νₑ[i, j, k] = calc_νᶜᶜᶜ(i, j, k, grid, closure, buoyancy, U, C)
end

@kernel function calculate_nonlinear_tracer_diffusivity!(κₑ, grid, closure, c, tracer_index, U)
    i, j, k = @index(Global, NTuple)
    @inbounds κₑ[i, j, k] = calc_κᶜᶜᶜ(i, j, k, grid, closure, c, tracer_index, U)
end