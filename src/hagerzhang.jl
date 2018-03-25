#
# Conjugate gradient line search implementation from:
#   W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
#     conjugate gradient method with guaranteed descent. ACM
#     Transactions on Mathematical Software 32: 113–137.
#
# Code comments such as "HZ, stage X" or "HZ, eqs Y" are with
# reference to a particular point in this paper.
#
# There are some modifications and/or extensions from what's in the
# paper (these may or may not be extensions of the cg_descent code
# that can be downloaded from Hager's site; his code has undergone
# numerous revisions since publication of the paper):
# linesearch: the Wolfe conditions are checked only after alpha is
#   generated either by quadratic interpolation or secant
#   interpolation, not when alpha is generated by bisection or
#   expansion. This increases the likelihood that alpha will be a
#   good approximation of the minimum.
#
# linesearch: In step I2, we multiply by psi2 only if the convexity
#   test failed, not if the function-value test failed. This
#   prevents one from going uphill further when you already know
#   you're already higher than the point at alpha=0.
#
# both: checks for Inf/NaN function values
#
# both: support maximum value of alpha (equivalently, c). This
#   facilitates using these routines for constrained minimization
#   when you can calculate the distance along the path to the
#   disallowed region. (When you can't easily calculate that
#   distance, it can still be handled by returning Inf/NaN for
#   exterior points. It's just more efficient if you know the
#   maximum, because you don't have to test values that won't
#   work.) The maximum should be specified as the largest value for
#   which a finite value will be returned.  See, e.g., limits_box
#   below.  The default value for alphamax is Inf. See alphamaxfunc
#   for cgdescent and alphamax for HagerZhang.



# TODO: Remove these bitfield things and create a proper
# tracing functionality instead

# Display flags are represented as a bitfield
# (not exported, but can use via LineSearches.ITER, for example)
const one64 = convert(UInt64, 1)
const FINAL       = one64
const ITER        = one64 << 1
const PARAMETERS  = one64 << 2
const GRADIENT    = one64 << 3
const SEARCHDIR   = one64 << 4
const ALPHA       = one64 << 5
const BETA        = one64 << 6
# const ALPHAGUESS  = one64 << 7 TODO: not needed
const BRACKET     = one64 << 8
const LINESEARCH  = one64 << 9
const UPDATE      = one64 << 10
const SECANT2     = one64 << 11
const BISECT      = one64 << 12
const BARRIERCOEF = one64 << 13
display_nextbit = 14


const DEFAULTDELTA = 0.1 # Values taken from HZ paper (Nocedal & Wright recommends 0.01?)
const DEFAULTSIGMA = 0.9 # Values taken from HZ paper (Nocedal & Wright recommends 0.1 for GradientDescent)


# NOTE:
#   [1] The type `T` in the `HagerZhang{T}` need not be the same `T` as in
#       `hagerzhang!{T}`; in the latter, `T` comes from the input vector `x`.
#   [2] the only method parameter that is not included in the
#       type is `iterfinitemax` since this value needs to be
#       inferred from the input vector `x` and not from the type information
#       on the parameters


"""
Conjugate gradient line search implementation from:
  W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
    conjugate gradient method with guaranteed descent. ACM
    Transactions on Mathematical Software 32: 113–137.
"""
@with_kw struct HagerZhang{T}
   delta::T = DEFAULTDELTA # c_1 Wolfe sufficient decrease condition
   sigma::T = DEFAULTSIGMA # c_2 Wolfe curvature condition (Recommend 0.1 for GradientDescent)
   alphamax::T = Inf
   rho::T = 5.0
   epsilon::T = 1e-6
   gamma::T = 0.66
   linesearchmax::Int = 50
   psi3::T = 0.1
   display::Int = 0
end

(ls::HagerZhang)(args...) = _hagerzhang!(args...,
      ls.delta, ls.sigma, ls.alphamax, ls.rho, ls.epsilon, ls.gamma,
      ls.linesearchmax, ls.psi3, ls.display)


function _hagerzhang!(df,
                     x::AbstractArray{T},
                     s::AbstractArray{T},
                     x_new::AbstractArray{T},
                     phi_0,
                     dphi_0,
                     c::T,
                     mayterminate::Bool,
                     delta::Real = T(DEFAULTDELTA),
                     sigma::Real = T(DEFAULTSIGMA),
                     alphamax::Real = convert(T,Inf),
                     rho::Real = convert(T,5),
                     epsilon::Real = convert(T,1e-6),
                     gamma::Real = convert(T,0.66),
                     linesearchmax::Integer = 50,
                     psi3::Real = convert(T,0.1),
                     display::Integer = 0) where T

    ϕ, dϕ, ϕdϕ = make_ϕ_dϕ_ϕdϕ(df, x_new, x, s)

    # Prevent values of `x_new` that are likely to make
    # ϕ(x_new) infinite
    iterfinitemax::Int = ceil(Int, -log2(eps(T)))
    alphas = [T(0)] # for bisection
    values = [phi_0]
    slopes = [dphi_0]
    if display & LINESEARCH > 0
        println("New linesearch")
    end

    (isfinite(phi_0) && isfinite(dphi_0)) || error("Initial value and slope must be finite")
    phi_lim = phi_0 + epsilon * abs(phi_0)
    @assert c > zero(T)
    @assert isfinite(c) && c <= alphamax
    phi_c, dphi_c = ϕdϕ(c)
    iterfinite = 1
    while !(isfinite(phi_c) && isfinite(dphi_c)) && iterfinite < iterfinitemax
        mayterminate = false
        iterfinite += 1
        c *= psi3
        phi_c, dphi_c = ϕdϕ(c)
    end
    if !(isfinite(phi_c) && isfinite(dphi_c))
        warn("Failed to achieve finite new evaluation point, using alpha=0")
        return zero(T) # phi_0
    end
    push!(alphas, c)
    push!(values, phi_c)
    push!(slopes, dphi_c)

    # If c was generated by quadratic interpolation, check whether it
    # satisfies the Wolfe conditions
    if mayterminate &&
          satisfies_wolfe(c, phi_c, dphi_c, phi_0, dphi_0, phi_lim, delta, sigma)
        if display & LINESEARCH > 0
            println("Wolfe condition satisfied on point alpha = ", c)
        end
        return c # phi_c
    end
    # Initial bracketing step (HZ, stages B0-B3)
    isbracketed = false
    ia = 1
    ib = 2
    @assert length(alphas) == 2
    iter = 1
    cold = -one(T)
    while !isbracketed && iter < linesearchmax
        if display & BRACKET > 0
            println("bracketing: ia = ", ia,
                    ", ib = ", ib,
                    ", c = ", c,
                    ", phi_c = ", phi_c,
                    ", dphi_c = ", dphi_c)
        end
        if dphi_c >= zero(T)
            # We've reached the upward slope, so we have b; examine
            # previous values to find a
            ib = length(alphas)
            for i = (ib - 1):-1:1
                if values[i] <= phi_lim
                    ia = i
                    break
                end
            end
            isbracketed = true
        elseif values[end] > phi_lim
            # The value is higher, but the slope is downward, so we must
            # have crested over the peak. Use bisection.
            ib = length(alphas)
            ia = ib - 1
            if c ≉  alphas[ib] || slopes[ib] >= zero(T)
                error("c = ", c)
            end
            # ia, ib = bisect(phi, lsr, ia, ib, phi_lim) # TODO: Pass options
            ia, ib = bisect!(ϕdϕ, alphas, values, slopes, ia, ib, phi_lim, display)
            isbracketed = true
        else
            # We'll still going downhill, expand the interval and try again
            cold = c
            c *= rho
            if c > alphamax
                c = (alphamax + cold)/2
                if display & BRACKET > 0
                    println("bracket: exceeding alphamax, bisecting: alphamax = ", alphamax, 
                    ", cold = ", cold, ", new c = ", c)
                end
                if c == cold || nextfloat(c) >= alphamax
                    return cold
                end
            end
            phi_c, dphi_c = ϕdϕ(c)
            iterfinite = 1
            while !(isfinite(phi_c) && isfinite(dphi_c)) && c > nextfloat(cold) && iterfinite < iterfinitemax
                alphamax = c
                iterfinite += 1
                if display & BRACKET > 0
                    println("bracket: non-finite value, bisection")
                end
                c = (cold + c) / 2
                phi_c, dphi_c = ϕdϕ(c)
            end
            if !(isfinite(phi_c) && isfinite(dphi_c))
                return cold
            elseif dphi_c < zero(T) && c == alphamax
                # We're on the edge of the allowed region, and the
                # value is still decreasing. This can be due to
                # roundoff error in barrier penalties, a barrier
                # coefficient being so small that being eps() away
                # from it still doesn't turn the slope upward, or
                # mistakes in the user's function.
                if iterfinite >= iterfinitemax
                    println("Warning: failed to expand interval to bracket with finite values. If this happens frequently, check your function and gradient.")
                    println("c = ", c,
                            ", alphamax = ", alphamax,
                            ", phi_c = ", phi_c,
                            ", dphi_c = ", dphi_c)
                end
                return c
            end
            push!(alphas, c)
            push!(values, phi_c)
            push!(slopes, dphi_c)
        end
        iter += 1
    end
    while iter < linesearchmax
        a = alphas[ia]
        b = alphas[ib]
        @assert b > a
        if display & LINESEARCH > 0
            println("linesearch: ia = ", ia,
                    ", ib = ", ib,
                    ", a = ", a,
                    ", b = ", b,
                    ", phi(a) = ", values[ia],
                    ", phi(b) = ", values[ib])
        end
        if b - a <= eps(b)
            return a # lsr.value[ia]
        end
        iswolfe, iA, iB = secant2!(ϕdϕ, alphas, values, slopes, ia, ib, phi_lim, delta, sigma, display)
        if iswolfe
            return alphas[iA] # lsr.value[iA]
        end
        A = alphas[iA]
        B = alphas[iB]
        @assert B > A
        if B - A < gamma * (b - a)
            if display & LINESEARCH > 0
                println("Linesearch: secant succeeded")
            end
            if nextfloat(values[ia]) >= values[ib] && nextfloat(values[iA]) >= values[iB]
                # It's so flat, secant didn't do anything useful, time to quit
                if display & LINESEARCH > 0
                    println("Linesearch: secant suggests it's flat")
                end
                return A
            end
            ia = iA
            ib = iB
        else
            # Secant is converging too slowly, use bisection
            if display & LINESEARCH > 0
                println("Linesearch: secant failed, using bisection")
            end
            c = (A + B) / convert(T, 2)

            phi_c, dphi_c = ϕdϕ(c)
            @assert isfinite(phi_c) && isfinite(dphi_c)
            push!(alphas, c)
            push!(values, phi_c)
            push!(slopes, dphi_c)

            ia, ib = update!(ϕdϕ, alphas, values, slopes, iA, iB, length(alphas), phi_lim, display)
        end
        iter += 1
    end

    throw(LineSearchException("Linesearch failed to converge, reached maximum iterations $(linesearchmax).",
                              alphas[ia]))


end

# Check Wolfe & approximate Wolfe
function satisfies_wolfe(c::T,
                         phi_c::Real,
                         dphi_c::Real,
                         phi_0::Real,
                         dphi_0::Real,
                         phi_lim::Real,
                         delta::Real,
                         sigma::Real) where T<:Number
    wolfe1 = delta * dphi_0 >= (phi_c - phi_0) / c &&
               dphi_c >= sigma * dphi_0
    wolfe2 = (2 * delta - 1) * dphi_0 >= dphi_c >= sigma * dphi_0 &&
               phi_c <= phi_lim
    return wolfe1 || wolfe2
end

# HZ, stages S1-S4
function secant(a::Real, b::Real, dphi_a::Real, dphi_b::Real)
    return (a * dphi_b - b * dphi_a) / (dphi_b - dphi_a)
end
function secant(alphas, values, slopes, ia::Integer, ib::Integer)
    return secant(alphas[ia], alphas[ib], slopes[ia], slopes[ib])
end
# phi
function secant2!(ϕdϕ,
                  alphas,
                  values,
                  slopes,
                  ia::Integer,
                  ib::Integer,
                  phi_lim::Real,
                  delta::Real = DEFAULTDELTA,
                  sigma::Real = DEFAULTSIGMA,
                  display::Integer = 0)
    phi_0 = values[1]
    dphi_0 = slopes[1]
    a = alphas[ia]
    b = alphas[ib]
    dphi_a = slopes[ia]
    dphi_b = slopes[ib]
    if !(dphi_a < zero(eltype(slopes)) && dphi_b >= zero(eltype(slopes)))
        error(string("Search direction is not a direction of descent; ",
                     "this error may indicate that user-provided derivatives are inaccurate. ",
                      @sprintf "(dphi_a = %f; dphi_b = %f)" dphi_a dphi_b))
    end
    c = secant(a, b, dphi_a, dphi_b)
    if display & SECANT2 > 0
        println("secant2: a = ", a, ", b = ", b, ", c = ", c)
    end
    @assert isfinite(c)
    # phi_c = phi(tmpc, c) # Replace
    phi_c, dphi_c = ϕdϕ(c)
    @assert isfinite(phi_c) && isfinite(dphi_c)

    push!(alphas, c)
    push!(values, phi_c)
    push!(slopes, dphi_c)

    ic = length(alphas)
    if satisfies_wolfe(c, phi_c, dphi_c, phi_0, dphi_0, phi_lim, delta, sigma)
        if display & SECANT2 > 0
            println("secant2: first c satisfied Wolfe conditions")
        end
        return true, ic, ic
    end

    iA, iB = update!(ϕdϕ, alphas, values, slopes, ia, ib, ic, phi_lim, display)
    if display & SECANT2 > 0
        println("secant2: iA = ", iA, ", iB = ", iB, ", ic = ", ic)
    end
    a = alphas[iA]
    b = alphas[iB]
    doupdate = false
    if iB == ic
        # we updated b, make sure we also update a
        c = secant(alphas, values, slopes, ib, iB)
    elseif iA == ic
        # we updated a, do it for b too
        c = secant(alphas, values, slopes, ia, iA)
    end
    if a <= c <= b
        if display & SECANT2 > 0
            println("secant2: second c = ", c)
        end
        # phi_c = phi(tmpc, c) # TODO: Replace
        phi_c, dphi_c = ϕdϕ(c)
        @assert isfinite(phi_c) && isfinite(dphi_c)

        push!(alphas, c)
        push!(values, phi_c)
        push!(slopes, dphi_c)

        ic = length(alphas)
        # Check arguments here
        if satisfies_wolfe(c, phi_c, dphi_c, phi_0, dphi_0, phi_lim, delta, sigma)
            if display & SECANT2 > 0
                println("secant2: second c satisfied Wolfe conditions")
            end
            return true, ic, ic
        end
        iA, iB = update!(ϕdϕ, alphas, values, slopes, iA, iB, ic, phi_lim, display)
    end
    if display & SECANT2 > 0
        println("secant2 output: a = ", alphas[iA], ", b = ", alphas[iB])
    end
    return false, iA, iB
end

# HZ, stages U0-U3
# Given a third point, pick the best two that retain the bracket
# around the minimum (as defined by HZ, eq. 29)
# b will be the upper bound, and a the lower bound
function update!(ϕdϕ,
                 alphas,
                 values,
                 slopes,
                 ia::Integer,
                 ib::Integer,
                 ic::Integer,
                 phi_lim::Real,
                 display::Integer = 0)
    a = alphas[ia]
    b = alphas[ib]
    # Debugging (HZ, eq. 4.4):
    @assert slopes[ia] < zero(eltype(slopes))
    @assert values[ia] <= phi_lim
    @assert slopes[ib] >= zero(eltype(slopes))
    @assert b > a
    c = alphas[ic]
    phi_c = values[ic]
    dphi_c = slopes[ic]
    if display & UPDATE > 0
        println("update: ia = ", ia,
                ", a = ", a,
                ", ib = ", ib,
                ", b = ", b,
                ", c = ", c,
                ", phi_c = ", phi_c,
                ", dphi_c = ", dphi_c)
    end
    if c < a || c > b
        return ia, ib, 0, 0  # it's out of the bracketing interval
    end
    if dphi_c >= zero(eltype(slopes))
        return ia, ic, 0, 0  # replace b with a closer point
    end
    # We know dphi_c < 0. However, phi may not be monotonic between a
    # and c, so check that the value is also smaller than phi_0.  (It's
    # more dangerous to replace a than b, since we're leaving the
    # secure environment of alpha=0; that's why we didn't check this
    # above.)
    if phi_c <= phi_lim
        return ic, ib, 0, 0  # replace a
    end
    # phi_c is bigger than phi_0, which implies that the minimum
    # lies between a and c. Find it via bisection.
    return bisect!(ϕdϕ, alphas, values, slopes, ia, ic, phi_lim, display)
end

# HZ, stage U3 (with theta=0.5)
function bisect!(ϕdϕ,
                 alphas::AbstractArray{T},
                 values,
                 slopes,
                 ia::Integer,
                 ib::Integer,
                 phi_lim::Real,
                 display::Integer = 0) where T
    gphi = convert(T, NaN)
    a = alphas[ia]
    b = alphas[ib]
    # Debugging (HZ, conditions shown following U3)
    @assert slopes[ia] < zero(T)
    @assert values[ia] <= phi_lim
    @assert slopes[ib] < zero(T)       # otherwise we wouldn't be here
    @assert values[ib] > phi_lim
    @assert b > a
    while b - a > eps(b)
        if display & BISECT > 0
            println("bisect: a = ", a, ", b = ", b, ", b - a = ", b - a)
        end
        d = (a + b) / convert(T, 2)
        phi_d, gphi = ϕdϕ(d)
        @assert isfinite(phi_d) && isfinite(gphi)

        push!(alphas, d)
        push!(values, phi_d)
        push!(slopes, gphi)

        id = length(alphas)
        if gphi >= zero(T)
            return ia, id # replace b, return
        end
        if phi_d <= phi_lim
            a = d # replace a, but keep bisecting until dphi_b > 0
            ia = id
        else
            b = d
            ib = id
        end
    end
    return ia, ib
end

"""
Initial step size algorithm from
  W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
    conjugate gradient method with guaranteed descent. ACM
    Transactions on Mathematical Software 32: 113–137.

If α0 is NaN, then procedure I0 is called at the first iteration,
otherwise, we select according to procedure I1-2, with starting value α0.
"""
@with_kw struct InitialHagerZhang{T}
    ψ0::T         = 0.01
    ψ1::T         = 0.2
    ψ2::T         = 2.0
    ψ3::T         = 0.1
    αmax::T       = Inf
    α0::T         = 1.0 # Initial alpha guess. NaN => algorithm calculates
    verbose::Bool = false
end

function (is::InitialHagerZhang)(state, phi_0, dphi_0, df)


    if isnan(state.f_x_previous) && isnan(is.α0)
        # If we're at the first iteration (f_x_previous is NaN)
        # and the user has not provided an initial step size (is.α0 is NaN),
        # then we
        # pick the initial step size according to HZ #I0
        state.alpha = _hzI0(state.x, NLSolversBase.gradient(df),
                            NLSolversBase.value(df),
                            convert(eltype(state.x), is.ψ0)) # Hack to deal with type instability between is{T} and state.x
        state.mayterminate = false
    else
        # Pick the initial step size according to HZ #I1-2
        state.alpha, state.mayterminate =
            _hzI12(state.alpha, df, state.x, state.s, state.x_ls, phi_0, dphi_0,
                   is.ψ1, is.ψ2, is.ψ3, is.αmax, is.verbose)
    end
    return state.alpha
end

# Pick the initial step size (HZ #I1-I2)
function _hzI12(alpha::T,
                df,
                x::AbstractArray{T},
                s::AbstractArray{T},
                x_new::AbstractArray{T},
                phi_0::T,
                dphi_0::T,
                psi1::Real = convert(T,0.2),
                psi2::Real = convert(T,2.0),
                psi3::Real = convert(T,0.1),
                alphamax::Real = convert(T, Inf),
                verbose::Bool = false) where T


     ϕ = make_ϕ(df, x_new, x, s)

    # Prevent values of `x_new` that are likely to make
    # ϕ(x_new) infinite
    iterfinitemax::Int = ceil(Int, -log2(eps(T)))

    alphatest = psi1 * alpha
    alphatest = min(alphatest, alphamax)

    phitest = ϕ(alphatest)

    iterfinite = 1
    while !isfinite(phitest)
        alphatest = psi3 * alphatest

        phitest = ϕ(alphatest)

        iterfinite += 1
        if iterfinite >= iterfinitemax
            return zero(T), true
            #             error("Failed to achieve finite test value; alphatest = ", alphatest)
        end
    end
    a = ((phitest-phi_0)/alphatest - dphi_0)/alphatest  # quadratic fit
    if verbose == true
        println("quadfit: alphatest = ", alphatest,
                ", phi_0 = ", phi_0,
                ", phitest = ", phitest,
                ", quadcoef = ", a)
    end
    mayterminate = false
    if isfinite(a) && a > zero(T) && phitest <= phi_0
        alpha = -dphi_0 / 2 / a # if convex, choose minimum of quadratic
        if alpha == 0
            error("alpha is zero. dphi_0 = ", dphi_0, ", phi_0 = ", phi_0, ", phitest = ", phitest, ", alphatest = ", alphatest, ", a = ", a)
        end
        if alpha <= alphamax
            mayterminate = true
        else
            alpha = alphamax
            mayterminate = false
        end
        if verbose == true
            println("alpha guess (quadratic): ", alpha,
                    ",(mayterminate = ", mayterminate, ")")
        end
    else
        if phitest > phi_0
            alpha = alphatest
        else
            alpha *= psi2 # if not convex, expand the interval
        end
    end
    alpha = min(alphamax, alpha)
    if verbose == true
        println("alpha guess (expand): ", alpha)
    end
    return alpha, mayterminate
end

# Generate initial guess for step size (HZ, stage I0)
function _hzI0(x::AbstractArray{T},
               gr::AbstractArray{T},
               f_x::T,
               psi0::T = convert(T,0.01)) where T
    alpha = one(T)
    gr_max = maximum(abs, gr)
    if gr_max != zero(T)
        x_max = maximum(abs, x)
        if x_max != zero(T)
            alpha = psi0 * x_max / gr_max
        elseif f_x != zero(T)
            alpha = psi0 * abs(f_x) / vecnorm(gr)
        end
    end
    return alpha
end
