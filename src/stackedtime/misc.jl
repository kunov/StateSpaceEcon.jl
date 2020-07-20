

export seriesoverlay
"""
    seriesoverlay(ts1, ts2)

Return a new [`TSeries`](@ref) over the full range of both arguments. The overlapping part
contains values from the last argument.

See also: [`dictoverlay`](@ref)

"""
function seriesoverlay(ts1::TSeries, ts2::TSeries)
    # Make a copy of the output sries
    tsout = deepcopy(ts2);
    # Range of the first TSeries
    Rng1 = mitrange(ts1);
    # Range of the second TSeries
    Rng2 = mitrange(ts2);
    if Rng1.start < Rng2.start
        tsout[Rng1.start:Rng2.start - 1] = ts1;
    end
    if Rng1.stop > Rng2.stop
        tsout[Rng2.stop + 1:Rng1.stop] = ts1;
    end
    return tsout
end

export dictoverlay
"""
    dictoverlay(d1, d2)

Merge two dictionaries. Common key where the values are [`TSeries`](@ref) of the
same frequency are overlayed. Otherwise, a common key takes the value of the
last Dict containing it.

See also: [`seriesoverlay`](@ref)
"""
function dictoverlay(D1::Dict{String,Any}, D2::Dict{String,Any})
    # Get keys
    K1 = keys(D1);
    K2 = keys(D2);
    # Combine the keys
    K = unique([collect(K1) ; collect(K2)]);
    # Pre-allocate output
    D3 = Dict{String,Any}();
    # Go over each key and update D3
    for k in K
        # Test where we can find the key
        t1 = in(k, K1)
        t2 = in(k, K2)
        if !t1
            # If we cannot find it in K1, we use D2
            push!(D3, k => D2[k])
        elseif !t2
            # If we cannot find it in K2, we use D1
            push!(D3, k => D1[k])
        else
            # If we find it in both D1 and D2
            if isa(D1[k], TSeries) && isa(D2[k], TSeries)
                # If both are TSeries, we overlay them.
                push!(D3, k => seriesoverlay(D1[k], D2[k]))
            else
                # Otherwise, we give priority to D2
                push!(D3, k => D2[k])
            end
        end
    end
    return D3 = deepcopy(D3)
end

export array2dict
"""
    array2dict(data, vars, start_date)

Convert the simulation data array to a dictionary.
"""
function array2dict(data::AbstractArray{Float64,2}, vars::AbstractArray{<:AbstractString,1}, start_date::MIT)::Dict{String,Any}
    Dict{String,Any}(vars[i] => TSeries(start_date, data[:,i]) for i ∈ 1:length(vars))
end

function array2dict(data::AbstractArray{Float64,2}, vars::AbstractArray{Symbol,1}, start_date::MIT)::Dict{String,Any}
    Dict{String,Any}(string(vars[i]) => TSeries(start_date, data[:,i]) for i ∈ 1:length(vars))
end

export array2data
"""
    array2data(data, vars, start_date)

Convert the simulation data array to a named tuple.

"""
function array2data(data::AbstractArray{Float64,2}, vars::AbstractArray{<:AbstractString,1}, start_date::MIT)
    names = tuple(Symbol.(vars)...)
    NamedTuple{names}([TSeries(start_date, data[:,i]) for i in 1:size(data, 2)])
end

function array2data(data::AbstractArray{Float64,2}, vars::AbstractArray{Symbol,1}, start_date::MIT)
    NamedTuple{tuple(vars...)}([TSeries(start_date, data[:,i]) for i in 1:size(data, 2)])
end

export dict2array
"""
    dict2array(d, vars; range)

Convert a dictionary of [`TSeries`](@ref) to a 2d array of simulation data for
the given range.  The `range` argument is optional and defaults to `nothing`.

"""
function dict2array(d::Dict{<:AbstractString,<:Any}, vars::AbstractArray{<:AbstractString,1}; range::Union{Nothing,AbstractUnitRange} = nothing)::Array{Float64,2}
    # Number of variables to consider
    vars_l = length(vars)
    # If the range is not provided, we check that the TSeries
    # all have the same range
    if range == nothing
        ranges = [mitrange(d[string(var)]) for var in vars]
        test_ranges = all([isequal(ranges[1], x) for x in ranges])
        # Issue an error message if necessary
        if test_ranges
            range = ranges[1];
        else
            error("The TSeries in the dictionary do not have the same range. Provide a range.")
        end
    end
    # Length of the range
    range_l = length(range)
    # Pre-allocate the matrix
    data = Array{Float64,2}(undef, range_l, length(vars))
    # Variable to detect if the concatenation of the data has been successful
    test_failed = false;
    # Create array to store variables that have missing data
    issues_var = Array{String,1}();
    # Concatenate the data
    for (col, var) in enumerate(vars)
        # Get the vector
        myvec = d[string(var)][range].values
        # Check the dimensions
        if length(myvec) == range_l
            # Allocate the data
            data[:,col] = myvec;
        else
            # We raise a flag and record which TSeries are incomplete
            test_failed = true;
            push!(issues_var, var);
        end
    end
    # After the loop, we issue an error message if the test has failed.
    if test_failed
        error("Data is missing within the range $(range) for these variables:\n $(issues_var)")
    end
    return data
end

function dict2array(d::Dict{String,<:Any}, vars::Array{Symbol,1}; range::Union{Nothing,AbstractUnitRange} = nothing)::Array{Float64,2}
    return dict2array(d, string.(vars); range = range)
end
