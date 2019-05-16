module FewShotAnomalyDetection

using Flux
using NNlib
using Distributions
using SpecialFunctions
using Adapt
using Random
using LinearAlgebra
using EvalCurves
using Pkg
using Statistics

include("flux_extensions.jl")
include("KNNmemory.jl")
include("bessel.jl")
include("svae.jl")
include("svaebase.jl")
include("svaetwocaps.jl")
include("svae_vamp.jl")
include("svae_vamp_means.jl")
include("vae.jl")

export SVAEbase, SVAEtwocaps, SVAEvamp, SVAEvampmeans, VAE, loss, wloss, log_pxexpectedz, pz, log_pz, log_px, log_pz_jacobian_encoder, log_pz_jacobian_decoder, samplez, zparams, printing_wloss, mem_wloss, log_det_jacobian_encoder, log_det_jacobian_decoder, hsplit1softp

end
