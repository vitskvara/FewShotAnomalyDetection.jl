"""
		Implementation of Hyperspherical Variational Auto-Encoders

		Original paper: https://arxiv.org/abs/1804.00891

		SVAEtwocaps(q,g,zdim,hue,μzfromhidden,κzfromhidden)

		q --- encoder - in this case encoder only encodes from input to a hidden
						layer which is then transformed into parameters for the latent
						layer by `μzfromhidden` and `κzfromhidden` functions
		g --- decoder
		zdim --- dimension of the latent space
		hue --- Hyperspherical Uniform Entropy that is part of the KL divergence but depends only on dimensionality so can be computed in constructor
		μzfromhidden --- function that transforms the hidden layer to μ parameter of the latent layer by normalization
		κzfromhidden --- transforms hidden layer to κ parameter of the latent layer using softplus since κ is a positive scalar
"""
mutable struct SVAEtwocaps{V<:Val} <: SVAE
	q
	g
	zdim
	hue
	μzfromhidden
	κzfromhidden
	priorμ
	priorκ
	variant::V

	"""
	SVAEtwocaps(q, g, hdim, zdim, T) Constructor of the S-VAE where `zdim > 3` and T determines the floating point type (default Float32)
	"""
end
SVAEtwocaps(q, g, hdim::Int, zdim::Int, μ, v::Symbol = :unit, T = Float32) = SVAEtwocaps(q, g, zdim, convert(T, huentropy(zdim)), Adapt.adapt(T, Chain(Dense(hdim, zdim), x -> normalizecolumns(x))), Adapt.adapt(T, Dense(hdim, 1, x -> σ.(x) .* 100)), μ, Flux.param(Adapt.adapt(T, [1.])), Val(v))
SVAEtwocaps(inputDim, hiddenDim, latentDim, numLayers, nonlinearity, layerType, v::Symbol = :unit, T::DataType = Float32) = SVAEtwocaps(inputDim, hiddenDim, latentDim, numLayers, nonlinearity, layerType, Flux.param(Adapt.adapt(T, normalize(randn(latentDim)))), v, T)
function SVAEtwocaps(inputDim, hiddenDim, latentDim, numLayers, nonlinearity, layerType, μ::AbstractVector, v::Symbol = :unit, T = Float32)
	encoder = Adapt.adapt(T, layerbuilder(inputDim, hiddenDim, hiddenDim, numLayers, nonlinearity, "", layerType))
	decoder = nothing
	if v == :unit
		decoder = Adapt.adapt(T, layerbuilder(latentDim, hiddenDim, inputDim, numLayers + 1, nonlinearity, "linear", layerType))
	elseif v == :scalarsigma
		decoder = Adapt.adapt(T, layerbuilder(latentDim, hiddenDim, inputDim + 1, numLayers + 1, nonlinearity, "linear", layerType))
	end
	return SVAEtwocaps(encoder, decoder, hiddenDim, latentDim, μ, v, T)
end

Flux.@treelike(SVAEtwocaps)

export closestz, manifoldz, log_pz_from_z, pz_from_z

function closestz(m::SVAEtwocaps, x, steps = 100)
	z = param(Flux.data(zparams(m, x)[1]))
	ps = Flux.Tracker.Params([z])
	opt = ADAM()
	_lkl(model, x, z) = mean(log_pxexpectedz(model, x, z) .- log_pz_from_z(model, z))
	li = Flux.data(_lkl(m, x, z))
	Flux.train!((i) -> -_lkl(m, x, z), ps, 1:steps, opt)
	le = Flux.data(_lkl(m, x, z))
	println("initial = ",li, " final = ",le)
	Flux.data(z)
end
	
function manifoldz(m::SVAEtwocaps, x, steps = 100)
	z = param(Flux.data(zparams(m, x)[1]))
	ps = Flux.Tracker.Params([z])
	opt = ADAM()
	li = Flux.data(mean(log_pxexpectedz(m, x, z)))
	Flux.train!((i) -> -mean(log_pxexpectedz(m, x, z)), ps, 1:steps, opt)
	le = Flux.data(mean(log_pxexpectedz(m, x, z)))
	println("initial = ",li, " final = ",le)
	Flux.data(z)
end

jacobian_decoder(m::SVAEtwocaps{V}, z) where {V <: Val{:scalarsigma}} = Flux.Tracker.jacobian(a -> m.g(a)[1:end-1], z) 

function log_pxexpectedz(m::SVAEtwocaps{V}, x) where {V <: Val{:scalarsigma}}
	xgivenz = m.g(zparams(m, x)[1])[1:end - 1, :]
	log_normal(x, xgivenz, collect(softplus.(xgivenz[end, :])'))
end

function log_pxexpectedz(m::SVAEtwocaps{V}, x, z) where {V <: Val{:scalarsigma}}
	xgivenz = m.g(z)[1:end - 1, :]
	log_normal(x, xgivenz, collect(softplus.(xgivenz[end, :])'))
end

function log_pz(m::SVAEtwocaps, x)
	μz, _ = zparams(m, x)
	return log_vmf_c(Flux.Tracker.data(μz), Flux.Tracker.data(m.priorμ), Flux.Tracker.data(m.priorκ[1]))
end

log_pz_from_z(m::SVAEtwocaps, z) = log_vmf_c(Flux.Tracker.data(z), Flux.Tracker.data(m.priorμ), Flux.Tracker.data(m.priorκ[1]))

pz(m::SVAEtwocaps, x) = exp.(log_pz(m, x))
pz_from_z(m::SVAEtwocaps, z) = exp.(log_pz_from_z(m, z))

function log_px(m::SVAEtwocaps{V}, x::Matrix, k::Int = 100) where {V <: Val{:scalarsigma}}
	x = [x[:, i] for i in 1:size(x, 2)]
	return map(a -> log_px(m, a, k), x)
end

function log_px(m::SVAEtwocaps{V}, x::Vector, k::Int = 100) where {V <: Val{:scalarsigma}}
	μz, κz = zparams(m, x)
	# println("μz: $μz")
	# println("κz: $κz")
	μz = repeat(Flux.Tracker.data(μz), 1, k)
	κz = repeat(Flux.Tracker.data(κz), 1, k)
	z = Flux.Tracker.data(samplez(m, μz, κz))
	xgivenz = Flux.Tracker.data(m.g(z))

	pxgivenz = log_normal(repeat(x, 1, k), xgivenz[1:end - 1, :], collect(softplus.(xgivenz[end, :])'))
	# println("pxgivenz: $pxgivenz")
	pz = log_vmf_wo_c(z, m.priorμ, m.priorκ[1])
	# println("pz $pz")
	qzgivenx = log_vmf_wo_c(z, μz[:, 1], κz[1])
	# println("qzgivenx: $qzgivenx")

	return log(sum(exp.(Flux.Tracker.data(pxgivenz .+ pz .- qzgivenx))))
end

function set_normal_μ(m::SVAEtwocaps, μ)
	κz = 1.
	T = eltype(m.hue)
	m.priorμ = Flux.param(Adapt.adapt(T, Flux.Tracker.data(μ)))
	m.priorκ = Flux.param(Adapt.adapt(T, [κz]))
end

function set_normal_μ_nonparam(m::SVAEtwocaps, μ)
	κz = 1.
	T = eltype(m.hue)
	m.priorμ = Adapt.adapt(T, Flux.Tracker.data(μ))
	m.priorκ = Adapt.adapt(T, [κz])
end

function set_normal_hypersphere(m::SVAEtwocaps, anomaly)
	μz, _ = zparams(m, anomaly)
	set_normal_μ(m, μz)
end

function wloss(m::SVAEtwocaps{V}, x, β, d) where {V <: Val{:unit}}
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	# zp = samplehsuniform(size(z))
	prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
	Ω = d(z, prior)
	xgivenz = m.g(z)
	return Flux.mse(x, xgivenz) + β * Ω
end

function printing_wloss(m::SVAEtwocaps{V}, x, β, d) where {V <: Val{:unit}}
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	# zp = samplehsuniform(size(z))
	prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
	Ω = d(z, prior)
	xgivenz = m.g(z)
	re = Flux.mse(x, xgivenz)
	println("loglkl: $re | Wass-dist: $β x $Ω")
	return re + β * Ω
end

function wloss(m::SVAEtwocaps{V}, x, d) where {V <: Val{:scalarsigma}}
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
	Ω = d(z, prior)
	xgivenz = m.g(z)
	return -mean(log_normal(x, xgivenz[1:end - 1, :], collect(softplus.(xgivenz[end, :])'))) + Ω
end

function printing_wloss(m::SVAEtwocaps{V}, x, d) where {V <: Val{:scalarsigma}}
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
	Ω = d(z, prior)
	xgivenz = m.g(z)
	re = -mean(log_normal(x, xgivenz[1:end - 1, :], collect(softplus.(xgivenz[end, :])')))
	println("loglkl: $re | Wass-dist: $Ω")
	return re + Ω
end

function wloss_semi_supervised(m::SVAEtwocaps{V}, x, y, β, d, α) where {V <: Val{:unit}}
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	xgivenz = m.g(z)

	if count(y .== 1) > 0
		anom_ids = findall(y .== 1)
		anom_ids = anom_ids[rand(1:length(anom_ids), length(y))]
		μzanom = μz[:, anom_ids]
		κzanom = κz[anom_ids]
		zanom = samplez(m, μzanom, collect(κzanom'))

		norm_ids = findall(y .== 0)
		norm_ids = norm_ids[rand(1:length(norm_ids), length(y))]
		μznorm = μz[:, norm_ids]
		κznorm = κz[norm_ids]
		znorm = samplez(m, μznorm, collect(κznorm'))

		anom_prior = samplez(m, ones(size(μz)) .* normalizecolumns(.-m.priorμ), ones(size(κz)) .* m.priorκ)
		norm_prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
		Ωnorm = d(znorm, norm_prior)
		Ωanom = d(zanom, anom_prior)
		return Flux.mse(x, xgivenz) + β * (α .* Ωnorm .+ (1 - α) .* Ωanom)
	else
		norm_prior = samplez(m, ones(size(μz)) .* normalizecolumns(m.priorμ), ones(size(κz)) .* m.priorκ)
		Ωnorm = d(z, norm_prior)
		return Flux.mse(x, xgivenz) + β * Ωnorm
	end
end
