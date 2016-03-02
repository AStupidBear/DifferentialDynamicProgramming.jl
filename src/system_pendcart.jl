
plotstuff_pendcart(args...) = println("Install package Plots.jl to plot results in the end of demo_pendcart")

@require Plots begin
function plotstuff_pendcart(x00, u00, x,u,cost00,cost,otrace)
    cp = Plots.subplot(n=3,nr=1)
    sp = Plots.subplot(x00',title=["\$x_$(i)\$" for i=1:size(x00,1)]', lab="Simulation")
    Plots.subplot!(cp,[u00' cost00[2:end]], title=["Control signal", "Cost"]', lab="Simulation")

    Plots.subplot!(sp,x', title=["\$x_$(i)\$" for i=1:size(x00,1)]', lab="Optimized", xlabel="Time step", legend=true)
    Plots.plot!(cp[1,1],u', legend=true, title="Control signal",lab="Optimized")
    Plots.plot!(cp[1,2],cost[2:end], legend=true, title="Cost",lab="Optimized",xscale=:log10, xlabel="Time step")

    totalcost = [ t.cost for t in otrace]
    iters = sum(totalcost .> 0)
    filter!(x->x>0,totalcost)
    Plots.plot!(cp[1,3], totalcost,title="Total cost", xlabel="Iteration", legend=false)
end
end

function demo_pendcart()

    function fsys_closedloop(t,x,L,xd)
        dx = copy(x)
        dx[1] -= pi
        u = -(L*dx)[1]
        xd[1] = x[2]
        xd[2] = -g/l * sin(x[1]) + u/l * cos(x[1])
        xd[3] = x[4]
        xd[4] = u
    end

    function fsys(t,x,u,xd)
        xd[1] = x[2]
        xd[2] = -g/l * sin(x[1]) + u/l * cos(x[1])
        xd[3] = x[4]
        xd[4] = u
    end

    function dfsys(x,u, t)
        x + h*[x[2]; -g/l*sin(x[1])+u/l*cos(x[1]); x[4]; u]
    end


    function cost_quadratic(x,u)
        d = (x.-goal)
        0.5(d'*Q*d + u'R*u)[1]
    end

    function cost_quadratic(x::Matrix,u)
        d = (x.-goal)
        T = size(u,2)
        c = Vector{Float64}(T+1)
        for t = 1:T
            c[t] = 0.5(d[:,t]'*Q*d[:,t] + u[:,t]'R*u[:,t])[1]
        end
        c[end] = cost_quadratic(x[:,end][:],[0.0])
        return c
    end

    function dcost_quadratic(x,u)
        cx  = Q*(x.-goal)
        cu  = R.*u
        cxu = zeros(D,1)
        return cx,cu,cxu
    end


    function lin_dyn_f(x,u,i)
        u[isnan(u)] = 0
        f = dfsys(x,u,i)
        c = cost_quadratic(x,u)
        return f,c
    end

    function lin_dyn_fT(x)
        cost_quadratic(x,0.0)
    end


    function lin_dyn_df(x,u,i::UnitRange)
        u[isnan(u)] = 0
        I = length(i)
        D = size(x,1)
        nu = size(u,1)
        fx = Array{Float64}(D,D,I)
        fu = Array{Float64}(D,1,I)
        cx,cu,cxu = dcost_quadratic(x,u)
        cxx = Q
        cuu = [R]
        for ii = i
            fx[:,:,ii] = [0 1 0 0;
            -g/l*cos(x[1,ii])-u[ii]/l*sin(x[1,ii]) 0 0 0;
            0 0 0 1;
            0 0 0 0]
            fu[:,:,ii] = [0, cos(x[1,ii])/l, 0, 1]
            ABd = expm([fx[:,:,ii]*h  fu[:,:,ii]*h; zeros(nu, D + nu)])# ZoH sampling
            fx[:,:,ii] = ABd[1:D,1:D]
            fu[:,:,ii] = ABd[1:D,D+1:D+nu]
        end
        fxx=fxu=fuu = []
        return fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu
    end

    function lin_dyn_df(x,u,i)
        u[isnan(u)] = 0
        D = size(x,1)
        fx = Array{Float64}(D,D)
        fu = Array{Float64}(D,1)
        cx,cu,cxu = dcost_quadratic(x,u)
        cxx = Q
        cuu = R
        fx = [0 1 0 0;
        -g/l*cos(x[1])-u/l*sin(x[1]) 0 0 0;
        0 0 0 1;
        0 0 0 0]

        fu = [0, cos(x[1])/l, 0, 1]
        fxx=fxu=fuu = []
        return fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu
    end


    """
    Simulate a pendulum on a cart using the non-linear equations
    """
    function simulate_pendcart(x0,L, dfsys, cost)
        x = zeros(4,N)
        u = zeros(1,T)
        x[:,1] = x0
        u[1] = 0
        for t = 2:T
            dx     = copy(x[:,t-1])
            dx[1] -= pi
            u[t]   = clamp(-(L*dx)[1],lims[1],lims[2])
            x[:,t] = dfsys(x[:,t-1],u[t],0)
        end
        dx     = copy(x[:,T])
        dx[1] -= pi
        uT     = clamp(-(L*dx)[1],lims[1],lims[2])
        x[:,T+1] = dfsys(x[:,T],uT,0)
        c = cost(x,u)

        return x, u, c
    end



    T     = 800                     # Number of time steps
    N     = T+1
    g     = 9.82
    l     = 0.35                    # Length of pendulum
    h     = 0.01                    # Sample time
    lims  = 20.0*[-1 1]             # control limits, e.g. ones(m,1)*[-1 1]*.6
    goal  = [π,0,0,0]               # Reference point
    A     = [0 1 0 0;               # Linearlized system dynamics matrix
    g/l 0 0 0;
    0 0 0 1;
    0 0 0 0]
    B     = [0, -1/l, 0, 1]
    C     = eye(4)                  # Assume all states are measurable
    D     = 4

    sys   = ss(A,B,C,zeros(4))
    Q     = h*diagm([10,5,1,10])    # State weight matrix
    R     = h*1                     # Control weight matrix
    L     = lqr(sys,Q,R)            # Calculate the optimal state feedback
    L    += abs(0.2L).*randn(size(L))

    x0 = [π-0.1,0,0,0]



    # Simulate the closed loop system to get a reasonable initial trajectory
    x00, u00, cost00 = simulate_pendcart(x0, L, dfsys, cost_quadratic)


    fx  = A
    fu  = B
    cxx = Q
    cxu = zeros(size(B))
    cuu = R

    f(x,u,i)   = lin_dyn_f(x,u,i)
    fT(x)      = lin_dyn_fT(x)
    df(x,u,i)  = lin_dyn_df(x,u,i)
    # plotFn(x)  = plot(squeeze(x,2)')

    # run the optimization
    println("Entering iLQG function")
    @time x, u, L, Vx, Vxx, cost, otrace = iLQG(f,fT,df, x00, u00,
    lims=lims,
    cost=cost00,
    plotFn= x -> 0,
    regType=2,
    Alpha= logspace(0,-10,20),
    verbosity=10,
    lambdaMax=1e20);

    plotstuff_pendcart(x00, u00, x,u,cost00,cost,otrace)
    return nothing
end
