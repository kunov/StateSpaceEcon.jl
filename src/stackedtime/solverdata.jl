
using ModelBaseEcon.AbstractModelEvaluationData

export StackedTimeSolverData
"""
    StackedTimeSolverData <: AbstractSolverData

The data structure used in the stacked time algorithm.

**TODO** Add all the details here.
"""
struct StackedTimeSolverData <: AbstractSolverData
    "Number of time periods" 
    NT::Int64 
    "Number of variables"
    NV::Int64
    "Number of shocks"
    NS::Int64
    "Number of unknowns = variables + shocks + aux variables"
    NU::Int64
    "Final condition type: `fcgiven` or `fclevel` or `fcslope`."
    FC::FCType
    "List of vectors for the time indexes of blocks of the matrix."
    TT::Vector{Vector{Int64}}
    "List of vectors for the row indexes of each block."
    II::Vector{Vector{Int64}}
    "List of vectors for the column indexes of each block."
    JJ::Vector{Vector{Int64}}
    "Inverse lookup for the column indexes."
    BI::Vector{Vector{Int64}}
    "Jacobian matrix cache."
    J::SparseMatrixCSC{Float64,Int64}
    "Correction to J in case FC == fcslope. See description of algorithm."
    CiSc::SparseMatrixCSC{Float64,Int64}   # Correction to J to account for FC in the case of fcslope    
    "The steady state data, used for FC ∈ (fclevel, fcslope)."
    SSV::AbstractVector{Float64}
    "The `evaldata` from the model, used to evaluate RJ and R!"
    evaldata::AbstractModelEvaluationData
    "Keep track of which variables are set by exogenous constraints."
    exog_mask::Vector{Bool}
    "Keep track of which variables are set by final conditions."
    fc_mask::Vector{Bool}
    "Keep track of which variables are \"active\" for the solver."
    solve_mask::Vector{Bool}
    "Cache the LU decomposition of the active part of J"
    luJ::Array{Any}
end


"""
    set_plan!(sd::StackedTimeSolverData, model, plan; changed=false)

Implementation for the Stacked Time algorithm.
Plan must have the same range as the original plan.

By default the data structure is updated only if an actual change in the plan is
detected. Setting the `changed` flag to `true` forces the update even if the plan
seems unchanged. This necessary only in rare circumstances.
"""
function set_plan!(sd::StackedTimeSolverData, m::Model, p::Plan; changed = false)
    if sd.NT != length(p.range)
        error("Unable to update using a simulation plan of different length.")
    end

    # LinearIndices used for indexing the columns of the global matrix
    LI = LinearIndices((p.range, 1:sd.NU))

    sim = m.maxlag + 1:sd.NT - m.maxlead
    NTFC = m.maxlead
    
    # Assume initial conditions are set correctly to exogenous in the constructor
    # We only update the masks during the simulation periods
    unknowns = m.allvars
    foo = falses(sd.NU)
    for t in sim
        s = p.exogenous[t]
        si = indexin(s, unknowns)
        fill!(foo, false)
        foo[si] .= true
        if !all(foo .== sd.exog_mask[LI[t,:]])
            sd.exog_mask[LI[t,:]] .= foo
            changed = true
        end
    end

    # Update the solve_mask array
    if changed 
        sd.solve_mask .= .!(sd.fc_mask .| sd.exog_mask)
        @assert !any(sd.exog_mask .& sd.fc_mask)
        @assert sum(sd.solve_mask) == size(sd.J, 1)
    end


    # Update the Jacobian correction matrix, if exogenous plan changed
    if changed && (sd.FC == fcslope)
        # This is a mess! TODO Boyan: document what's going on here
        foo = falses(sd.NU * sd.NT)
        foo[LI[last(sim),1:sd.NV]] .= true
        foo[LI[last(sim),sd.NV + sd.NS + 1:sd.NU]] .= true
        JJfoo = repeat(findall(foo[sd.solve_mask]), inner = NTFC)
        IIfoo = vcat((NTFC * (vi - 1) .+ (1:NTFC) for vi in Iterators.flatten((1:sd.NV, sd.NV + sd.NS + 1:sd.NU)) if !sd.exog_mask[LI[last(sim),vi]])...)
        sd.CiSc .= sparse(IIfoo, JJfoo, fill(Float64(-1), length(JJfoo)), NTFC * sd.NU, size(sd.J, 1))
        sd.CiSc.nzval .= -1
    end
    if changed 
        # cached lu is no longer valid, since active columns have changed
        sd.luJ[1] = nothing
    end

    return sd
end

"""
    make_BI(J, II)

Prepares the `BI` array for the solver data.
Called from the constructor of `StackedTimeSolverData`.

!!! note
    Internal function, not meant to be called directly by the user.
"""
function make_BI(JMAT::SparseMatrixCSC{Float64,Int64}, II::AbstractVector{<:AbstractVector{Int64}})
    # Computes the set of indexes in JMAT.nzval corresponding to blocks of equations in II

    # Bar is the inverse map of II, i.e. Bar[j] = i <=> II[i] contains j
    local Bar = zeros(Int64, size(JMAT, 1))
    for i in axes(II, 1)
        Bar[II[i]] .= i
    end

    # start with empty lists in BI
    local BI = [[] for _ in II] 

    # iterate the non-zero elements of JMAT and record their row numbers in BI
    local rows = rowvals(JMAT)
    local n = size(JMAT, 2)
    for i = 1:n
        for j in nzrange(JMAT, i)
            row = rows[j]
            push!(BI[ Bar[row] ], j)
        end
    end
    return BI
end

"""
    SimulationSolverData(model, plan, fctype)


"""
function SimulationSolverData(m::Model, p::Plan, fctype::FCType)

    # NOTE: we do not verify the steady state, just make sure it's been assigned
    if fctype ∈ (fclevel, fcslope) && !issssolved(m)
        error("Steady state must be solved in order to use it to set the final conditions.")
    end

    NT = length(p.range)
    init = 1:m.maxlag
    term = NT - m.maxlead + 1:NT
    sim = m.maxlag + 1:NT - m.maxlead
    NTFC = length(term)
    NTSIM = length(sim)
    NTIC = length(init)

    # @assert NTIC+NTSIM+NTFC == NT
    # @assert isempty((collect(init)∩collect(sim))∪(collect(init)∩collect(sim))∪(collect(sim)∩collect(term)))

    unknowns = vcat(m.variables, m.shocks, m.auxvars)
    nunknowns = length(unknowns)

    nvars = length(m.variables)
    nshks = length(m.shocks)
    nauxs = length(m.auxvars)

    equations = m.alleqns
    nequations = length(equations)

    # LinearIndices used for indexing the columns of the global matrix
    LI = LinearIndices((p.range, 1:nunknowns))

    # Initialize empty arrays
    TT = Vector{Int64}[] # the time indexes of the block, used when updating values in global_RJ
    II = Vector{Int64}[] # the row indexes
    JJ = Vector{Int64}[] # the the column indexes

    # Prep the Jacobian matrix
    neq::Int64 = 0 # running counter of equations added to matrix
    # Model equations are the same for each sim period, just shifted according to t
    Jblock = [ti + NT * (vi - 1) for eqn in equations for (ti, vi) in eqn.vinds]
    Iblock = [i for (i, eqn) in enumerate(equations) for _ in eqn.vinds]
    Tblock = -m.maxlag:m.maxlead
    @timer for t in sim
        push!(TT, t .+ Tblock)
        push!(II, neq .+ Iblock)
        push!(JJ, t .+ Jblock)
        neq += nequations
    end
    # Construct the 
    @timer begin
        I = vcat(II...)
        J = vcat(JJ...)
        JMAT = sparse(I, J, fill(NaN64, size(I)), NTSIM * nequations, NT * nunknowns)
    end

    # We no longer need the exact indexes of all non-zero entires in the Jacobian matrix.
    # We do however need the set of equation indexes for each sim period
    @timer foreach(sort! ∘ unique!, II)

    # BI holds the indexes in JMAT.nzval for each block of equations
    # @timer JMAT.nzval .= 1:nnz(JMAT)  # encode nnz entries with their index
    # @timer BI = [JMAT[ii,:].nzval for ii in II]  # re-distribute the nnz indexes accorting to II
    BI = make_BI(JMAT, II)  # same as the two lines above, but faster

    # We also need the times of the final conditions
    push!(TT, term)

    ##############  The following code constructs the matrix imposing final conditions. 
    ##############  We don't need it anymore, but we kept the code in case we do in the future.
    # # Final conditions
    # if fctype ∈ (fcgiven, fclevel)
    #     # @timer push!(TT, repeat(term, outer=nunknowns))
    #     @timer push!(TT, term)
    #     @timer push!(II, 1:NTFC*nunknowns)
    #     @timer push!(JJ, vec(LI[term,:]))
    # elseif fctype == fcslope
    #     # the first index of term is 
    #     # @timer push!(TT, repeat(vec([term.-1 term]'), outer=nunknowns))
    #     @timer push!(TT, term)
    #     @timer push!(II, repeat(1:NTFC*nunknowns, inner=2))
    #     @timer push!(JJ, vec([vec(LI[term.-1,:]) vec(LI[term,:])]'))
    # else
    #     error("Not implemented - unknown fctype $(fctype).")
    # end
    # JFCMAT = sparse(II[end], JJ[end], ones(Float64, axes(II[end])), NTFC*nunknowns, NT*nunknowns)
    # (sort! ∘ unique!)(II[end])
    # BIFC = make_BI(JFCMAT, II[end:end])
    # if fctype == fcslope
    #     # for the variables we set the t-1 coefficient to -1.0 (diff = slope of sstate)
    #     @timer JFCMAT.nzval[BIFC[end][1:2:end]] .= -1.0
    #     # for the shocks we set the t-1 coefficient to 0.0 (value = 0)
    #     @timer JFCMAT.nzval[BIFC[end][NTFC*nvars*2+1:2:NTFC*(nvars+nshks)*2]] .= 0.0
    # end

    # 
    exog_mask::Vector{Bool} = falses(nunknowns * NT)
    # Initial conditions are set as exogenous values
    exog_mask[vec(LI[init,:])] .= true
    # The exogenous values during sim are set in set_plan!() call below.

    # Final conditions are complicated 
    fc_mask::Vector{Bool} = falses(nunknowns * NT)
    fc_mask[vec(LI[term,:])] .= true

    # The solve_mask is redundant. We pre-compute and store it for speed
    solve_mask = .!(fc_mask .| exog_mask)

    g = SimulationSolverData(NT, nvars, nshks, nunknowns, fctype, TT, II, JJ, BI, JMAT, 
                             sparse([], [], Float64[], NTFC * nunknowns, size(JMAT, 1)), 
                             m.sstate.values, m.evaldata, exog_mask, fc_mask, solve_mask, 
                             [nothing])

    return set_plan!(g, m, p; changed = true)
end