# using Pkg
# pkg"add Oceananigans GLMakie"

using Printf
using Statistics
using GLMakie
using Oceananigans
using Oceananigans.Units
using Oceananigans.OutputReaders: FieldTimeSeries

grid = RegularRectilinearGrid(topology = (Periodic, Bounded, Bounded),
                              size = (64, 64, 32),
                              halo = (3, 3, 3),
                              x = (0, 1000kilometers),
                              y = (0, 2000kilometers),
                              z = (-3kilometers, 0))

@show grid

# # Boundary conditions
#
# A channel-centered jet and overturning circulation are driven by wind stress
# and an alternating pattern of surface cooling and surface heating with
# parameters

Qᵇ = 5e-9                 # buoyancy flux magnitude [m² s⁻³]
y_shutoff = 5/6 * grid.Ly # shutoff location for buoyancy flux [m]
τ = 2e-4                  # surface kinematic wind stress [m² s⁻²]
μ = 1 / 100days           # bottom drag damping time-scale [s⁻¹]

# The buoyancy flux has a sinusoidal pattern in `y`,

@inline buoyancy_flux(x, y, t, p) = ifelse(y < p.y_shutoff, p.Qᵇ * cos(3π * y / p.Ly), 0)

buoyancy_flux_bc = FluxBoundaryCondition(buoyancy_flux, parameters=(Ly=grid.Ly, y_shutoff=y_shutoff, Qᵇ=Qᵇ))

# At the surface we impose a wind stress with sinusoidal variation in `y`,

@inline u_stress(x, y, t, p) = - p.τ * sin(π * y / p.Ly)

u_stress_bc = FluxBoundaryCondition(u_stress, parameters=(τ=τ, Ly=grid.Ly))

# Linear bottom drag on `u` and `v` provides a sink of momentum

@inline u_drag(x, y, t, u, μ) = - μ * u
@inline v_drag(x, y, t, v, μ) = - μ * v

u_drag_bc = FluxBoundaryCondition(u_drag, field_dependencies=:u, parameters=μ)
v_drag_bc = FluxBoundaryCondition(v_drag, field_dependencies=:v, parameters=μ)

# To summarize,

b_bcs = TracerBoundaryConditions(grid, top = buoyancy_flux_bc)
u_bcs = UVelocityBoundaryConditions(grid, top = u_stress_bc, bottom = u_drag_bc)
v_bcs = VVelocityBoundaryConditions(grid, bottom = v_drag_bc)

# # Sponge layer
#
# A forcing term that relaxes the buoyancy field to a prescribed stratification
# at the northern wall produces an overturning circulation.
#
# We declare parameters as `const` so we can reference them as global variables
# in our forcing functions.

const Δb = 0.02                 # cross-channel buoyancy jump [m s⁻²]
const h = 1kilometer            # decay scale of stable stratification (N² ≈ Δb / h) [m]
const y_sponge = 1980kilometers # southern boundary of sponge layer [m]
const Ly = grid.Ly              # channel width [m]
const Lz = grid.Lz              # channel depth [m]

@inline b_target(x, y, z, t) = Δb * (y / Ly + exp(z / h))
@inline northern_mask(x, y, z) = max(0, y - y_sponge) / (Ly - y_sponge)

b_forcing = Relaxation(target=b_target, mask=northern_mask, rate=7days)

# # Turbulence closures
#
# A horizontally Laplacian diffusivity destroys enstrophy and buoyancy variance
# created by mesoscale turbulence, while a convective adjustment scheme creates
# a surface mixed layer due to surface cooling.

horizontal_diffusivity = AnisotropicDiffusivity(νh=100)

convective_adjustment = ConvectiveAdjustmentVerticalDiffusivity(convective_κz = 1.0,
                                                                convective_νz = 1.0,
                                                                background_κz = 1e-4,
                                                                background_νz = 1e-4)

# # Model building
#
# We build a model on a BetaPlane with an ImplicitFreeSurface.

model = HydrostaticFreeSurfaceModel(architecture = CPU(),                                           
                                    grid = grid,
                                    free_surface = ImplicitFreeSurface(),
                                    momentum_advection = WENO5(),
                                    tracer_advection = WENO5(),
                                    buoyancy = BuoyancyTracer(),
                                    coriolis = BetaPlane(latitude=-45),
                                    closure = (convective_adjustment, horizontal_diffusivity),
                                    tracers = :b,
                                    boundary_conditions = (b=b_bcs, u=u_bcs, v=v_bcs),
                                    forcing = (b=b_forcing,),
                                    )

@show model

# # Initial Conditions
#
# Our initial condition is an unstable, geostrophically-balanced shear flow
# and stable buoyancy stratification superposed with surface-concentrated
# random noise.

## Random noise concentrated at the top
u★, h★ = sqrt(τ), h / 10
ϵ(z) = u★ * exp(z / h★)

f = model.coriolis.f₀
β = model.coriolis.β

uᵢ(x, y, z) = (z + Lz) / (f + β * y) * (Δb / Ly) + 1e-3 * ϵ(z)
vᵢ(x, y, z) = 1e-3 * ϵ(z)
bᵢ(x, y, z) = b_target(x, y, z, 0)

set!(model, u=uᵢ, v=vᵢ, b=bᵢ)

# # Simulation setup
#
# We set up a simulation with adaptive time-stepping and a simple progress message.

wizard = TimeStepWizard(cfl=0.2, Δt=10minutes, max_change=1.1, max_Δt=20minutes)

print_progress(sim) = @printf("[%05.2f%%] i: %d, t: %s, max(u): (%6.3e, %6.3e, %6.3e) m/s, next Δt: %s\n",
                              100 * (sim.model.clock.time / sim.stop_time),
                              sim.model.clock.iteration,
                              prettytime(sim.model.clock.time),
                              maximum(abs, sim.model.velocities.u),
                              maximum(abs, sim.model.velocities.v),
                              maximum(abs, sim.model.velocities.w),
                              prettytime(sim.Δt.Δt))

simulation = Simulation(model, Δt=wizard, stop_time=10day, progress=print_progress, iteration_interval=10)

u, v, w = model.velocities
b = model.tracers.b

ζ = ComputedField(∂x(v) - ∂y(u))

Γ_op = @at (Center, Center, Center) ∂x(b)^2 + ∂y(b)^2
Γ = ComputedField(Γ_op)

outputs = merge(model.velocities, model.tracers, (ζ=ζ, Γ=Γ))

simulation.output_writers[:checkpointer] = Checkpointer(model,
                                                        schedule = TimeInterval(100days),
                                                        prefix = "eddying_channel",
                                                        force = true)

simulation.output_writers[:fields] = JLD2OutputWriter(model, outputs,
                                                      schedule = TimeInterval(4hours),
                                                      prefix = "eddying_channel",
                                                      field_slicer = nothing,
                                                      force = true)

@show simulation

run!(simulation)

u_timeseries = FieldTimeSeries("eddying_channel.jld2", "u")
b_timeseries = FieldTimeSeries("eddying_channel.jld2", "b")
ζ_timeseries = FieldTimeSeries("eddying_channel.jld2", "ζ")
Γ_timeseries = FieldTimeSeries("eddying_channel.jld2", "Γ")

xζ, yζ, zζ = nodes((Face, Face, Center), grid)
xu, yu, zu = nodes((Face, Center, Center), grid)
xc, yc, zc = nodes((Center, Center, Center), grid)

kwargs = (algorithm=:absorption, absorption=10.0f0, colormap=:balance, show_axis=false)

iter = Node(1)

u′ = @lift interior(u_timeseries[$iter])
b′ = @lift interior(b_timeseries[$iter])
ζ′ = @lift interior(ζ_timeseries[$iter])
Γ′ = @lift interior(Γ_timeseries[$iter])

u_clims = @lift extrema(interior(u_timeseries[$iter]))
b_clims = @lift extrema(interior(b_timeseries[$iter]))
ζ_clims = @lift extrema(interior(ζ_timeseries[$iter]))
Γ_clims = @lift extrema(interior(Γ_timeseries[$iter]))

fig = Figure(resolution = (2000, 1600))

ax_u = fig[1, 1] = LScene(fig)
ax_b = fig[1, 2] = LScene(fig)
ax_ζ = fig[2, 1] = LScene(fig)
ax_Γ = fig[2, 2] = LScene(fig)

volume!(ax_u, xζ, yζ, zζ * 100, u′; colorrange=u_clims, kwargs...) 
volume!(ax_b, xζ, yζ, zζ * 100, b′; colorrange=b_clims, kwargs...) 
volume!(ax_ζ, xζ, yζ, zζ * 100, ζ′; colorrange=ζ_clims, kwargs...) 
volume!(ax_Γ, xc, yc, zc * 100, Γ′; colorrange=Γ_clims, kwargs...) 

nframes = length(ζ_timeseries.times)

record(fig, "eddying_channel.mp4", 1:nframes, framerate=12) do i
    @info "Plotting frame $i of $nframes..."
    iter[] = i
end