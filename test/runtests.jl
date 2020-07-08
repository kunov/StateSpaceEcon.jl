using StateSpaceEcon
using Test


@testset "1dsolvers" begin
    # f(x) = (x-2)*(x-3) = a x^2 + b x + c with vals = [a, x, b, c]
    let f(v) = v[1] * v[2]^2 + v[3] * v[2] + v[4],
        fdf(v) = (f(v), [v[2]^2, v[1] * v[2] * 2 + v[3], v[2], 1.0]),
        vals = [1.0, NaN, -5.0, 6.0]

        vals[2] = 0.0
        @test StateSpaceEcon.SteadyStateSolver.newton1!(fdf, vals, 2; tol = eps(), maxiter = 8)
        @test vals ≈ [1.0, 2.0, -5.0, 6.0] atol = 1e3 * eps()

        vals[2] = 6.0
        @test StateSpaceEcon.SteadyStateSolver.newton1!(fdf, vals, 2; tol = eps(), maxiter = 8)
        @test vals ≈ [1.0, 3.0, -5.0, 6.0] atol = 1e3 * eps()

        vals[2] = 0.0
        @test StateSpaceEcon.SteadyStateSolver.bisect!(f, vals, 2, fdf(vals)[2][2]; tol = eps())
        @test vals ≈ [1.0, 2.0, -5.0, 6.0] atol = 1e3 * eps()

        vals[2] = 6.0
        @test StateSpaceEcon.SteadyStateSolver.bisect!(f, vals, 2, fdf(vals)[2][2]; tol = eps())
        @test vals ≈ [1.0, 3.0, -5.0, 6.0] atol = 1e3 * eps()
    end
end