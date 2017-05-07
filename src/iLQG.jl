import Base: length
EmptyMat3 = Array(Float64,0,0,0)
EmptyMat2 = Array(Float64,0,0)
emptyMat3(P) = Array(P,0,0,0)
emptyMat2(P) = Array(P,0,0)
type Trace
    iter::Int64
    λ::Float64
    dλ::Float64
    cost::Float64
    alpha::Float64
    grad_norm::Float64
    improvement::Float64
    reduce_ratio::Float64
    time_derivs::Float64
    time_forward::Float64
    time_backward::Float64
    Trace() = new(0,0.,0.,0.,0.,0.,0.,0.,0.,0.,0.)
end

type GaussianDist{P}
    T::Int
    n::Int
    m::Int
    fx::Array{P,3}
    fu::Array{P,3}
    Σ::Array{P,3}
    μx::Array{P,2}
    μu::Array{P,2}
end

GaussianDist(P) = GaussianDist(0,0,0,emptyMat3(P),emptyMat3(P),emptyMat3(P),emptyMat2(P),emptyMat2(P))
Base.isempty(gd::GaussianDist) = gd.T == gd.n == gd.m == 0
type GaussianTrajDist{P}
    policy::GaussianDist{P}
    dynamics::GaussianDist{P}
end


include("klutils.jl")

"""
iLQG - solve the deterministic finite-horizon optimal control problem.

minimize sum_i cost(x[:,i],u[:,i]) + cost(x[:,end])
s.t.  x[:,i+1] = f(x[:,i],u[:,i])

Inputs
======
`f, fT, df`

1) step:
`xnew,cost = f(x,u,i)` is called during the forward pass.
Here the state x and control u are vectors: size(x)==(n,),
size(u)==(m,). The time index `i` is a scalar.


2) final:
`cost = fT(x)` is called at the end the forward pass to compute
the final cost.

3) derivatives:
`fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu = df(x,u)` computes the
derivatives along a trajectory. In this case size(x)==(n, N) where N
is the trajectory length. size(u)==(m, N). The time indexes are I=(1:N).
Dimensions match the variable names e.g. size(fxu)==(n, n, m, N)
If cost function or system is time invariant, the dimension of the corresponding
derivatives can be reduced by dropping the time dimension

`x0` - The initial state from which to solve the control problem.
Should be a column vector. If a pre-rolled trajectory is available
then size(x0)==(n, N) can be provided and cost set accordingly.

`u0` - The initial control sequence. A matrix of size(u0)==(m, N)
where m is the dimension of the control and N is the number of state
transitions.

Outputs
=======
`x` - the optimal state trajectory found by the algorithm.
size(x)==(n, N)

`u` - the optimal open-loop control sequence.
size(u)==(m, N)

`L` - the optimal closed loop control gains. These gains multiply the
deviation of a simulated trajectory from the nominal trajectory x.
size(L)==(m, n N)

`Vx` - the gradient of the cost-to-go. size(Vx)==(n, N)

`Vxx` - the Hessian of the cost-to-go. size(Vxx)==(n, n N)

`cost` - the costs along the trajectory. size(cost)==(1, N)
the cost-to-go is V = fliplr(cumsum(fliplr(cost)))

`λ` - the final value of the regularization parameter

`trace` - a trace of various convergence-related values. One row for each
iteration, the columns of trace are
`[iter λ alpha g_norm dcost z sum(cost) dλ]`
see below for details.

`timing` - timing information
---------------------- user-adjustable parameters ------------------------
defaults

`lims`,           [],            control limits
`alpha`,          logspace(0,-3,11), backtracking coefficients
`tol_fun`,         1e-7,          reduction exit criterion
`tol_grad`,        1e-4,          gradient exit criterion
`max_iter`,        500,           maximum iterations
`λ`,         1,             initial value for λ
`dλ`,        1,             initial value for dλ
`λfactor`,   1.6,           λ scaling factor
`λmax`,      1e10,          λ maximum value
`λmin`,      1e-6,          below this value λ = 0
`regType`,        1,             regularization type 1: q_uu+λ*I 2: V_xx+λ*I
`reduce_ratio_min`,           0,             minimal accepted reduction ratio
`diff_fun`,         -,             user-defined diff for sub-space optimization
`plot`,           1,             0: no  k>0: every k iters k<0: every k iters, with derivs window
`verbosity`,      2,             0: no  1: final 2: iter 3: iter, detailed
`plot_fun`,         x->0,          user-defined graphics callback
`cost`,           [],            initial cost for pre-rolled trajectory

This code consists of a port and extension of a MATLAB library provided by the autors of
`   INPROCEEDINGS{author={Tassa, Y. and Mansard, N. and Todorov, E.},
booktitle={Robotics and Automation (ICRA), 2014 IEEE International Conference on},
title={Control-Limited Differential Dynamic Programming},
year={2014}, month={May}, doi={10.1109/ICRA.2014.6907001}}`
"""
function iLQG(f,fT,df, x0, u0;
    lims         = [],
    alpha        = logspace(0,-3,11),
    tol_fun      = 1e-7,
    tol_grad     = 1e-4,
    max_iter     = 500,
    λ            = 1,
    dλ           = 1,
    λfactor      = 1.6,
    λmax         = 1e10,
    λmin         = 1e-6,
    regType     = 1,
    reduce_ratio_min = 0,
    diff_fun     = -,
    plot         = 1,
    verbosity    = 2,
    plot_fun     = x->0,
    cost         = [],
    kl_step      = 0,
    traj_prev    = 0
    )
    debug("Entering iLQG")

    # --- initial sizes and controls
    n   = size(x0, 1)          # dimension of state vector
    m   = size(u0, 1)          # dimension of control vector
    N   = size(u0, 2)          # number of state transitions
    u   = u0                   # initial control sequence
    η   = 1.                   # TODO: this init value has not been confirmed
    traj_new  = GaussianDist(Float64)
    # traj_prev = GaussianDist(Float64)

    # --- initialize trace data structure
    trace = [Trace() for i in 1:min( max_iter+1,1e6)]
    trace[1].iter = 1
    trace[1].λ = λ
    trace[1].dλ = dλ



    # --- initial trajectory
    debug("Setting up initial trajectory")
    if size(x0,2) == 1 # only initial state provided
        diverge = true
        for alphai =  alpha
            debug("# test different backtracing parameters alpha and break loop when first succeeds")
            x,un,cost,_ = forward_pass(traj_new,x0[:,1],alphai*u,[],1,f,fT, lims,diff_fun)
            debug("# simplistic divergence test")
            if all(abs.(vec(x)) .< 1e8)
                u = un
                diverge = false
                break
            end
        end
    elseif size(x0,2) == N
        debug("# pre-rolled initial forward pass, initial traj provided, e.g. from demonstration")
        x        = x0
        diverge  = false
        isempty(cost) && error("Initial trajectory supplied, initial cost must also be supplied")
    else
        error("pre-rolled initial trajectory must be of correct length (size(x0,2) == N)")
    end

    trace[1].cost = sum(cost)
    #     plot_fun(x) # user plotting

    if diverge
        Vx=Vxx   = NaN
        L        = zeros(m,n,N)
        cost     = []
        trace    = trace[1]
        if verbosity > 0
            @printf("\nEXIT: Initial control sequence caused divergence\n")
        end
        return
    end

    # constants, timers, counters
    flg_change = true
    dcost      = 0.
    expected   = 0.
    div        = 0.
    print_head = 10 # print headings every print_head lines
    last_head  = print_head
    g_norm     = Vector{Float64}()
    t_start    = time()
    verbosity > 0 && @printf("\n---------- begin iLQG ----------\n")

    iter = accepted_iter = 1
    while accepted_iter <= max_iter
        trace[iter].iter = iter
        back_pass_done   = false
        l                = Matrix{Float64}()
        dV               = Vector{Float64}()
        reduce_ratio     = 0.
        traj_prev        = traj_new
        # ====== STEP 1: differentiate dynamics and cost along new trajectory
        if flg_change
            tic()
            fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu = df(x, u)
            trace[iter].time_derivs = toq()
            flg_change   = false
        end
        # Determine what kind of system we are dealing with
        linearsys = isempty(fxx) && isempty(fxu) && isempty(fuu); debug("linear system: $linearsys")

        # ====== STEP 2: backward pass, compute optimal control law and cost-to-go
        while !back_pass_done
            tic()
            if kl_step > 0
                @show η
                cxkl,cukl,cxxkl,cuukl,cxukl = dkl(traj_new) # TODO: this may need both traj_new and traj_prev
                # @show size(cxkl),size(cukl),size(cxxkl),size(cuukl),size(cxukl)
                # @show size(cx),size(cu),size(cxx),size(cuu),size(cxu)
                cx,cu,cxx,cuu,cxu = cx./η.+cxkl, cu./η.+cukl, cxx./η.+cxxkl, cuu./η.+cuukl, cxu./η.+cxukl # TODO: If the special case ndims(cxx) == 2 it will be promoted to 3 dims and another back_pass method will be called, this works but can be sped up significantly
            end
            diverge, traj_new,Vx, Vxx,dV = if linearsys
                back_pass(cx,cu,cxx,cxu,cuu,fx,fu,λ, regType, lims,x,u)
            else
                back_pass(cx,cu,cxx,cxu,cuu,fx,fu,fxx,fxu,fuu,λ, regType, lims,x,u)
            end
            @show typeof(traj_new)

            trace[iter].time_backward = toq()

            if diverge > 0
                verbosity > 2 && @printf("Cholesky failed at timestep %d.\n",diverge)
                dλ = max(dλ*λfactor, λfactor)
                λ  = max(λ*dλ, λmin)
                if λ >  λmax; break; end
                continue
            end
            back_pass_done = true
        end

        k, K = traj_new.μu, traj_new.fx
        #  check for termination due to small gradient
        g_norm = mean(maximum(abs.(k) ./ (abs.(u)+1),1))
        trace[iter].grad_norm = g_norm
        if g_norm <  tol_grad && λ < 1e-5 && satisfied
            verbosity > 0 && @printf("\nSUCCESS: gradient norm < tol_grad\n")
            break
        end

        # ====== STEP 3: line-search to find new control sequence, trajectory, cost
        fwd_pass_done  = false
        xnew,unew,costnew,sigmanew = Matrix{Float64}(),Matrix{Float64}(),Vector{Float64}(),Matrix{Float64}()
        if back_pass_done
            tic()
            debug("#  serial backtracking line-search")
            for alphai = alpha
                # TODO: the error is that u+l*alphai is not entered as before, have to get it from traj_new?
                xnew,unew,costnew,sigmanew = forward_pass(traj_new, x0[:,1] ,u, x,alphai,f,fT, lims, diff_fun)
                dcost    = sum(cost) - sum(costnew)
                expected = -alphai*(dV[1] + alphai*dV[2])
                reduce_ratio = if expected > 0
                    dcost/expected
                else
                    warn("negative expected reduction: should not occur")
                    sign(dcost)
                end
                if reduce_ratio > reduce_ratio_min
                    fwd_pass_done = true
                    @show size(xnew),size(unew),size(sigmanew)
                    # TODO: detta steget ska nog göras vid ett annat tillfälle
                    η, satisfied, div = calc_η(xnew,unew,sigmanew,η, traj_new, traj_prev, kl_step)
                    break
                end
            end
            alphai = fwd_pass_done ? alphai : NaN
            trace[iter].time_forward = toq()
        end

        # ====== STEP 4: accept step (or not), print status

        #  print headings
        if verbosity > 1 && last_head == print_head
            last_head = 0
            @printf("%-12s", "iteration     cost    reduction     expected    gradient    log10(λ)\n")
        end

        if fwd_pass_done
            if verbosity > 1
                @printf("%-12d%-12.6g%-12.3g%-12.3g%-12.3g%-12.1f\n",
                iter, sum(cost), dcost, expected, g_norm, log10(λ))
                last_head += 1
            end
            dλ = min(dλ / λfactor, 1/ λfactor)
            λ *= dλ

            #  accept changes
            x,u,cost  = xnew,unew,costnew
            flg_change = true
            plot_fun(x)
            if dcost < tol_fun && satisfied#  terminate ?
                verbosity > 0 &&  @printf("\nSUCCESS: cost change < tol_fun\n")
                break
            end
            accepted_iter += 1
        else #  no cost improvement
            dλ  = max(dλ * λfactor,  λfactor)#  increase λ
            λ   = max(λ * dλ,  λmin)
            if verbosity > 1
                @printf("%-12d%-12s%-12.3g%-12.3g%-12.3g%-12.1f\n",
                iter,"NO STEP", dcost, expected, g_norm, log10(λ))
                last_head = last_head+1
            end
            if λ > λmax #  terminate ?
                verbosity > 0 && @printf("\nEXIT: λ > λmax\n")
                break
            end
            push!(trace, Trace())
        end
        #  update trace
        trace[iter].λ           = λ
        trace[iter].dλ          = dλ
        trace[iter].alpha       = alphai
        trace[iter].improvement = dcost
        trace[iter].cost        = sum(cost)
        trace[iter].reduce_ratio = reduce_ratio
        graphics( plot,x,u,cost,K,Vx,Vxx,fx,fxx,fu,fuu,trace[1:iter],0)
        iter += 1
    end

    # save λ/dλ
    trace[iter].λ  = λ
    trace[iter].dλ = dλ

    iter ==  max_iter &&  verbosity > 0 && @printf("\nEXIT: Maximum iterations reached.\n")

    iter == 1 && error("Failure: no iterations completed, something is wrong. Try enabling the debug flag in DifferentialDynamicProgramming.jl for verbose printing.")


    div > kl_step && abs(div - kl_step) > 0.1*kl_step && warn("KL divergence too high when done")

    diff_t  = [trace[i].time_derivs for i in 1:iter]
    diff_t  = sum(diff_t[!isnan(diff_t)])
    back_t  = [trace[i].time_backward for i in 1:iter]
    back_t  = sum(back_t[!isnan(back_t)])
    fwd_t   = [trace[i].time_forward for i in 1:iter]
    fwd_t   = sum(fwd_t[!isnan(fwd_t)])
    total_t = time()-t_start
    if verbosity > 0
        info = 100/total_t*[diff_t, back_t, fwd_t, (total_t-diff_t-back_t-fwd_t)]
        @printf("\n iterations:   %-3d\n
        final cost:   %-12.7g\n
        final grad:   %-12.7g\n
        final λ: %-12.7e\n
        time / iter:  %-5.0f ms\n
        total time:   %-5.2f seconds, of which\n
        derivs:     %-4.1f%%\n
        back pass:  %-4.1f%%\n
        fwd pass:   %-4.1f%%\n
        other:      %-4.1f%% (graphics etc.)\n =========== end iLQG ===========\n",iter,sum(cost[:]),g_norm,λ,1e3*total_t/iter,total_t,info[1],info[2],info[3],info[4])
    end

    return x, u, traj_new, Vx, Vxx, cost, trace
end


function forward_pass(traj_new, x0,u,x,alpha,f,fT,lims,diff)
    n         = size(x0,1)
    m,N       = size(u)
    xnew      = Array(eltype(x0),n,N)
    xnew[:,1] = x0
    unew      = copy(u)
    cnew      = zeros(N)
    debug("Entering forward_pass loop")
    for i = 1:N
        if !isempty(traj_new)
            unew[:,i] .+= traj_new.μu[:,i]*alpha
        end
        if !isempty(traj_new.fx)
            dx = diff(xnew[:,i], x[:,i])
            unew[:,i] .+= traj_new.fx[:,:,i]*dx
        end
        if !isempty(lims)
            unew[:,i] = clamp.(unew[:,i],lims[:,1], lims[:,2])
        end
        xnewi, cnew[i]  = f(xnew[:,i], unew[:,i], i)
        if i < N
            xnew[:,i+1] = xnewi
        end
    end
    # cnew[N+1] = fT(xnew[:,N+1])
    sigmanew = zeros(m+n,m+n,N) # TODO: this function should calculate the covariance matrix as well
    return xnew,unew,cnew,sigmanew
end
