"""
Calculate the Q terms related to the KL-constraint.
Qtt is [Qxx Qxu; Qux Quu]
Qt is [Qx; Qu]
These terms should be added to the Q terms calculated in the backwards pass to produce the final Q terms.
This Function should be called from within the backwards_pass Function or just prior to it to adjust the cost derivative matrices.
"""
function dkl(traj_new)
    isempty(traj_new) && (return (0,0,0,0,0))
    m,n,T  = traj_new.m,traj_new.n,traj_new.T
    cx,cu,cxx,cuu,cxu = zeros(n,T),zeros(m,T),zeros(n,n,T),zeros(m,m,T),zeros(n,m,T)
    for t in 1:T
        K, k       = traj_new.fx[:,:,t], traj_new.μu[:,t]
        Σi         = traj_new.Σ[:,:,t]#inv(traj_new.Σ[:,:,t] + 1e-5*I) # TODO: the value that is save is actually Quu, which itself is inverse of policy covariance
        cx[:,t],cu[:,t],cxx[:,:,t],cuu[:,:,t],cxu[:,:,t]  = dkli(Σi,K,k)
    end
    return cx,cu,cxx,cuu,cxu
end


function dkli(Σi,K,k)
    cx  = K'*Σi*k
    cu  = -Σi*k
    cxx = K'*Σi*K
    cuu = Σi #TODO: defenetely + sign here?
    cxu = -K'Σi #TODO: maybe -Σi*K? Does fuck up array dims later, https://github.com/cbfinn/gps/blob/master/python/gps/algorithm/traj_opt/traj_opt_lqr_python.py#L355
    cx,cu,cxx,cuu,cxu
end

function KLmv(Σi,K,k)
    M =
    [K'*Σi*K  -K'*Σi;
    -Σi*K    Σi ]
    K', Σi, k
    v = [K'*Σi*k  -Σi*k]
    M,v
end

"""
Compute KL divergence between new and previous trajectory
distributions.

μ_new: (n+m)×T, mean of new trajectory distribution (xnew, unew).
Σ_new: n×n×T , variance of new trajectory distribution.
"""
function kl_div(xnew,unew, Σ_new, new_traj::GaussianDist, prev_traj::GaussianDist)
    (isempty(new_traj) || isempty(prev_traj)) && (return 0)
    μ_new = [xnew; unew]
    T     = new_traj.T
    # m     = size(new_traj.fu,1)
    kldiv = zeros(T)
    for t = 1:T
        μt    = μ_new[:,t]
        Σt    = Σ_new[:,:,t]
        Kp    = prev_traj.fx[:,:,t]
        Kn    = new_traj.fx[:,:,t]
        kp    = prev_traj.μu[:,t]
        kn    = new_traj.μu[:,t]
        Σp    = prev_traj.Σ[:,:,t]
        Σn    = new_traj.Σ[:,:,t]
        Σip   = inv(Σp + 1e-5*I) # TODO: I added some regularization here, should maybe be a hyper parameter?
        Σin   = inv(Σn + 1e-5*I)
        Mp,vp = KLmv(Σip,Kp,kp)
        Mn,vn = KLmv(Σin,Kn,kn)
        cp    = prev_traj.dV[2]
        cn    = new_traj.dV[2]

        kldiv[t] = -0.5μt'(Mn-Mp)*μt -  μt'(vn-vp) - cn + cp -0.5sum(Σt*(Mn-Mp)) -0.5logdet(Σn) + 0.5logdet(Σp)
        kldiv[t] = max(0,kldiv[t])
    end
    return sum(kldiv)
end


function kl_div_wiki(xnew,unew, Σ_new, new_traj::GaussianDist, prev_traj::GaussianDist)
    μ_new = xnew# [xnew; unew] verkar inte som att unew behövs??
    T,m     = new_traj.T, new_traj.m
    kldiv = zeros(T)
    for t = 1:T
        μt     = μ_new[:,t]
        Σt     = Σ_new[:,:,t]
        Kp     = prev_traj.fx[:,:,t]
        Kn     = new_traj.fx[:,:,t]
        kp     = prev_traj.μu[:,t]
        kn     = new_traj.μu[:,t]
        Σp    = prev_traj.Σ[:,:,t]# TODO: the value that is save is actually Quu, which itself is inverse of policy covariance
        Σn    = new_traj.Σ[:,:,t]
        Σip     = inv(Σp + 1e-15*I) # TODO: I added some regularization here, should maybe be a hyper parameter?
        Σin     = inv(Σn + 1e-15*I)
        dim    = size(Σip,1)
        k_diff = kp-kn
        K_diff = Kp-Kn
        try
            kldiv[t] = 1/2 * (trace(Σip*Σn) + k_diff⋅(Σip*k_diff) - dim + logdet(Σip) - logdet(Σin) )
            kldiv[t] +=  ( μt'K_diff'Σip*K_diff*μt + 1/2 *trace(K_diff'Σip*K_diff*Σt) )[1]
        catch e
            println(e)
            @show Σip, Σin
            error("quitting")
        end
    end
    kldiv = max.(0,kldiv) # TODO: change to negative, seem to have a sign error
    return sum(kldiv)
end


# sum(diag(K_diff'inv_prev'K_diff'sigma)) +
# 2 * k_diff'inv_prev'K_diff'mu
# TODO: Calculate Σ in the forwards pass, requires covariance of forward dynamics model. Is this is given by the Pkn matrix from the Kalman model?


"""
new_η, satisfied, divergence = calc_η(xnew,unew,sigmanew,η, traj_new, traj_prev, kl_step)
This Function caluculates the step size
"""
function calc_η(xnew,unew,sigmanew,η, traj_new, traj_prev, kl_step)
    kl_step > 0 || (return (1., true,0))
    min_η  = 1e-5#1e-5 # TODO: these should be hyperparameters
    max_η  = 1e16#1e16 # TODO: these should be hyperparameters
    divergence    = kl_div_wiki(xnew,unew,sigmanew, traj_new, traj_prev)
    constraint_violation    = divergence - kl_step
    # Convergence check - constraint satisfaction.
    satisfied = (constraint_violation) < 0.1*kl_step # allow some small constraint violation # TODO: Why the absolute value on constraint_violation?
    satisfied && debug(@sprintf("KL: %12.7f / %12.7f, converged",  divergence, kl_step))

    if constraint_violation < 0 # η was too big.
        max_η = η
        geom = √(min_η*max_η)  # Geometric mean.
        new_η = max(geom, 0.1*max_η)
        debug(@sprintf("KL: %12.7f / %12.7f, η too big, new η: %12.7f",  divergence, kl_step, new_η))
    else # η was too small.
        min_η = η
        geom = √(min_η*max_η)  # Geometric mean.
        new_η = min(geom, 10.0*min_η)
        debug(@sprintf("KL: %12.7f / %12.7f, η too small, new η: %12.7f",  divergence, kl_step, new_η))
    end
    return new_η, satisfied, divergence
end


# using Base.Test
# n,m,T = 1,1,1
#
# traj_new  = GaussianDist(Float64,T,n,m)
# traj_old  = GaussianDist(Float64,T,n,m)
# xnew = zeros(n,T)
# unew = zeros(m,T)
# Σnew = cat(3,[eye(n+m) for t=1:T]...)
# @test kl_div_wiki(xnew,unew, Σnew, traj_new, traj_old) == 0
#
# traj_new.μu = ones(m,T)
# kl_div_wiki(xnew,unew, Σnew, traj_new, traj_old)
#
# traj_new.μx = ones(m,T)
# kl_div_wiki(xnew,unew, Σnew, traj_new, traj_old)
#
# traj_new.Σ .*=2
# kl_div_wiki(xnew,unew, Σnew, traj_new, traj_old)
