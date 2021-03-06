abstract type SVAE end

normalizecolumns(m::AbstractArray{T, 2}) where {T<:Number} = m ./ sqrt.(sum(m .^ 2, dims = 1) .+ eps(T))
function normalizecolumns!(m::AbstractArray{T, 2}) where {T<:Number}
	m .= normalizecolumns(m)
end

"""
	vmfentropy(m, κ)

	Entropy of Von Mises-Fisher distribution
"""
vmfentropy(m, κ) = .-κ .* besselix(m / 2, κ) ./ besselix(m / 2 - 1, κ) .- ((m ./ 2 .- 1) .* log.(κ) .- (m ./ 2) .* log(2π) .- (κ .+ log.(besselix(m / 2 - 1, κ))))

"""
	huentropy(m)

	Entropy of Hyperspherical Uniform distribution
"""
huentropy(m) = m / 2 * log(π) + log(2) - lgamma(m / 2)

"""
	kldiv(model::SVAE, κ)

	KL divergence between Von Mises-Fisher and Hyperspherical Uniform distributions
"""
kldiv(model::SVAE, κ) = .- vmfentropy(model.zdim, κ) .+ model.hue

log_normal(x) = - sum((x .^ 2), dims = 1) ./ 2 .- size(x, 1) .* log(2π) ./ 2
log_normal(x, μ) = log_normal(x - μ)
log_normal(x,μ, σ2::AbstractArray{T}) where {T<:Number} = - sum((x - μ) .^ 2 ./ σ2 .+ log.(σ2 .* 2π), dims = 1) / 2

# Likelihood estimation of a sample x under VMF with given parameters taken from https://pdfs.semanticscholar.org/2b5b/724fb175f592c1ff919cc61499adb26996b1.pdf
# normalizing constant for density function of VMF
c(p, κ) = κ ^ (p / 2 - 1) / ((2π) ^ (p / 2) * besseli(p / 2 - 1, κ))

# log likelihood of one sample under the VMF dist with given parameters
log_vmf_c(x, μ, κ) = κ * μ' * x .+ log(c(length(μ), κ))
log_vmf_wo_c(x, μ, κ) = κ * μ' * x

pairwisecos(x, y) = max.(1 .- (x' * y), 0) # This is a bit of a hack to avoid the distance being negative due to float
pairwisecos(x) = pairwisecos(x, x)

k_imq(x, y, c) = sum( c./ (c .+ pairwisecos(x, y))) / (size(x, 2) * size(y, 2))
k_imq(x::T, c) where {T <: AbstractMatrix} = sum(c ./ (c .+ pairwisecos(x))) / (size(x, 2) * (size(x, 2) - 1))
k_imq(x::T, c) where {T <: AbstractVector} = zero(eltype(x))

mmd_imq(x,y,c) = k_imq(x,c) + k_imq(y,c) - 2 * k_imq(x,y,c)

function samplehsuniform(size...)
	v = randn(size...)
	v = normalizecolumns(v)
end

function log_pxexpectedz(m::SVAE, x)
	xgivenz = m.g(zparams(m, x)[1])
	Flux.Tracker.data(log_normal(x, xgivenz))
end

cart3dtoangular(x) = [acos(1.0 * x[3] / norm(x)), 1.0 * atan(x[2] / x[1])]

function cart2spherical(x)
	scoords = vcat([acot(x[i] / norm(x[(i + 1):end])) for i in 1:(length(x) - 2)]...)
	scoords = vcat(scoords, 2acot((x[end - 1] + norm(x[(end-1):end])) / x[end]))
end

jacobian_encoder(m::SVAE, x) = Flux.Tracker.jacobian(a -> Chain(m.q, m.μzfromhidden)(a), x)

function log_pz_jacobian_encoder(m::SVAE, x)
	if size(x, 2) > 1
		xs = [x[:, i] for i in 1:size(x, 2)]
		return map(x -> log_pz_jacobian_encoder_singleinstance(m, x), xs)
	else
		return log_pz_jacobian_encoder_singleinstance(m, x)
	end
end

function log_pz_jacobian_encoder_singleinstance(m::SVAE, x)
	@assert size(x, 2) == 1
	s = svd(jacobian_encoder(m, x).data)
	d = reduce(+, log.(abs.(s.S))) * 2
	d + log_pz(m, x)
end

jacobian_decoder(m::SVAE, z) = Flux.Tracker.jacobian(a -> m.g(a), z)

function log_pz_jacobian_decoder(m::SVAE, z)
	if size(z, 2) > 1
		zs = [z[:, i] for i in 1:size(z, 2)]
		return map(z -> log_pz_jacobian_decoder_singleinstance(m, z), zs)
	else
		return log_pz_jacobian_decoder_singleinstance(m, z)
	end
end

function log_pz_jacobian_decoder_singleinstance(m::SVAE, z)
	@assert size(z, 2) == 1
	s = svd(jacobian_decoder(m, z).data)
	d = reduce(+, log.(abs.(s.S))) * 2
	-d + log_pz_from_z(m, z)
end

# function log_pz_jacobian(m::SVAE, x, z)
# 	if size(x, 2) > 1
# 		xs = [x[:, i] for i in 1:size(x, 2)]
# 		zs = [z[:, i] for i in 1:size(z, 2)]
# 		return map((x, z) -> log_pz_jacobian_singleinstance(m, x, z), xs, zs)
# 	else
# 		return log_pz_jacobian_singleinstance(m, x, z)
# 	end
# end

# function log_pz_jacobian_singleinstance(m::SVAE, x, z)
# 	@assert size(x, 2) == 1
# 	s = svd(jacobian(m, x).data)
# 	d = reduce(+, log.(abs.(s.S)))
# 	d + log(pz_from_z(m, z))
# end

"""
	infer(m::SVAE, x)

	infer latent variables and sample output x
"""
function infer(m::SVAE, x)
	(μz, κz) = zparams(m, x)
	z = samplez(m, μz, κz)
	xgivenz = m.g(z)
	return xgivenz
end

"""
	zparams(model::SVAE, x)

	Computes μ and κ from the hidden layer
"""

function zparams(model::SVAE, x)
	hidden = model.q(x)
	# return model.μzfromhidden(hidden), max.(model.κzfromhidden(hidden), 100)
	return model.μzfromhidden(hidden), model.κzfromhidden(hidden)
end

"""
	zfromx(m::SVAE, x)

	convenience function that returns latent layer based on the input `x`
"""
zfromx(m::SVAE, x) = samplez(m, zparams(m, x)...)

"""
	samplez(m::SVAE, μz, κz)

	samples z layer based on its parameters
"""
function samplez(m::SVAE, μz, κz)
	ω = sampleω(m, κz)
	normal = Normal()
	v = Adapt.adapt(eltype(Flux.Tracker.data(κz)), rand(normal, size(μz, 1) - 1, size(μz, 2)))
	v = normalizecolumns(v)
	z = householderrotation(vcat(ω, sqrt.(1 .- ω .^ 2 .+ eps(Float32)) .* v), μz)
	return z
end

"""
	householderrotation(zprime, μ)

	uses Householder reflection to rotate the `zprime` vector according to mapping of e1 to μ
"""
function householderrotation(zprime, μ)
	e1 = similar(μ) .= 0
	e1[1, :] .= 1
	u = e1 .- μ
	normalizedu = normalizecolumns(u)
	return zprime .- 2 .* sum(zprime .* normalizedu, dims = 1) .* normalizedu
end

function sampleω(model::SVAE, κ)
	m = model.zdim
	c = @. sqrt(4κ ^ 2 + (m - 1) ^ 2)
	b = @. (-2κ + c) / (m - 1)
	a = @. (m - 1 + 2κ + c) / 4
	d = @. (4 * a * b) / (1 + b) - (m - 1) * log(m - 1)
	ω = rejectionsampling(m, a, b, d, κ)
	return ω
end

function rejectionsampling(m, a, b, d, κ)
	beta = Beta((m - 1) / 2, (m - 1) / 2)
	T = eltype(Flux.Tracker.data(a))
	ϵ, u = Adapt.adapt(T, rand(beta, size(a)...)), rand(T, size(a)...)

	accepted = isaccepted(ϵ, u, m, Flux.data(a), Flux.Tracker.data(b), Flux.data(d))
	it = 0
	while (!all(accepted)) & (it < 10000)
		mask = .! accepted
		ϵ[mask] = Adapt.adapt(T, rand(beta, sum(mask)))
		u[mask] = rand(T, sum(mask))
		accepted[mask] = isaccepted(mask, ϵ, u, m, Flux.data(a), Flux.data(b), Flux.data(d))
		it += 1
	end
	if it >= 10000
		println("Warning - sampler was stopped by 10000 iterations - it did not accept the sample!")
		println(m)
		println(a)
		println(b)
		println(d)
		println(κ)
		println(accepted)
	end
	return @. (1 - (1 + b) * ϵ) / (1 - (1 - b) * ϵ)
end

# function rejectionsampling(m, a, b, d)
# 	beta = Beta((m - 1) / 2, (m - 1) / 2)
# 	T = eltype(Flux.Tracker.data(a))
# 	ϵ, u = Adapt.adapt(T, rand(beta, size(a)...)), rand(T, size(a)...)
#
# 	accepted = isaccepted(ϵ, u, m, Flux.data(a), Flux.Tracker.data(b), Flux.data(d))
# 	while !all(accepted)
# 		mask = .! accepted
# 		ϵ[mask] = Adapt.adapt(T, rand(beta, sum(mask)))
# 		u[mask] = rand(T, sum(mask))
# 		ia = isaccepted(mask, ϵ, u, m, Flux.data(a), Flux.data(b), Flux.data(d))
# 		accepted[mask] = ia
# 	end
# 	return @. (1 - (1 + b) * ϵ) / (1 - (1 - b) * ϵ)
# end

isaccepted(mask, ϵ, u, m:: Int, a, b, d) = isaccepted(ϵ[mask], u[mask], m, a[mask], b[mask], d[mask]);
function isaccepted(ϵ, u, m:: Int, a, b, d)
	ω = @. (1 - (1 + b) * ϵ) / (1 - (1 - b) * ϵ)
	t = @. 2 * a * b / (1 - (1 - b) * ϵ)
	@. (m - 1) * log(t) - t + d >= log(u)
end
