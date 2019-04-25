"""
This module implements a memory, according to https://arxiv.org/abs/1703.03129,
that can be used as the last layer in a NN in the Flux framework.
"""

export KNNmemory, query, trainQuery!, augmentModelWithMemory

"""
    KNNmemory{T}
Structure that contains all the memory data.
"""
mutable struct KNNmemory{T <: Real}
    M::Matrix{T} # keys in the memory
    V::Vector{<:Integer} # values in the memory (labels)
    A::Vector{<:Integer} # age of a given key-value pair
    k::Integer # number of neighbors used in kNN
    α::Real # parameter setting the required distance between the nearest positive and negative sample in the kNN
    encoder # Transformation function that allows to store item in memory in one space and compute the distance in another
			# The final space has to be a hypersphere!
	encodeM # transposed transformation so it can be used on `M`

    """
        KNNmemory{T}(memorySize, keySize, k, labelCount, [α])
    Memory constructor that initializes it with random keys and random labels.
    # Arguments
    - `memorySize::Integer`: number of keys that can be stored in the memoryUpdate!
    - `keySize::Integer`: length of a key
    - `k::Integer`: number of k nearest neighbors to look for
    - `labelCount::Integer`: number of labels that are in the dataset (used for the random initialization)
	- `encoder`: Transformation function that allows to store item in memory in one space and compute the distance in another. Default is identity.
    - `α::Real`: parameter of the memory loss function that determines required distance between clusters
    """
    function KNNmemory{T}(memorySize::Integer, keySize::Integer, k::Integer, labelCount::Integer, encoder = x -> normalizecolumns(x), α::Real = 0.1) where T
        M = rand(T, memorySize, keySize) .* 2 .- 1
        V = rand(0:(labelCount - 1), memorySize)
        A = zeros(Int, memorySize)

        for i = 1:memorySize
            M[i,:] = normalize(M[i,:])
        end

        new(M, V, A, k > memorySize ? memorySize : k, convert(T, α), encoder, m -> collect(encoder(m')'))
    end
end

"""
    findNearestPositiveAndNegative(memory, kLargestIDs, v)
For given set of k nearest neighbours, find the closest two that have the same label `v` and a different label respectively.
`kLargestIDs::Vector{<:Integer}` contains k indices leading to the k most similar keys in the memorySize.
"""
function findNearestPositiveAndNegative(memory::KNNmemory, kLargestIDs::Vector{<:Integer}, v::Integer)
    nearestPositiveID = nothing
    nearestNegativeID = nothing

    # typically this should not result into too many iterations
    for i in 1:memory.k
        if nearestPositiveID == nothing && memory.V[kLargestIDs[i]] == v
            nearestPositiveID = kLargestIDs[i]
        end
        if nearestNegativeID == nothing && memory.V[kLargestIDs[i]] != v
            nearestNegativeID = kLargestIDs[i]
        end
        if nearestPositiveID != nothing && nearestNegativeID != nothing
            break
        end
    end

    #= We assume that there exists such i that memory.V[i] == v
        and also such j that memory.V[j] != v
list
        We also assume that this won't happen very often, otherwise,
        we would need to randomize this selection (possible TODO) =#

    if nearestPositiveID == nothing
        nearestPositiveID = Base.argmax(memory.V .== v)
    end
    if nearestNegativeID == nothing
        nearestNegativeID = Base.argmax(memory.V .!= v)
    end

    return nearestPositiveID, nearestNegativeID
end

"""
    memoryLoss(memory, q, nearestPosAndNegIDs)
Loss generated by the memory based on the lookup of a key-value pair for the key `q` - exactly as in the paper.
`nearestPosAndNegIDs::Tuple` represents ids of the closest key with the same and a different label respectively.
"""
memoryLoss(memory::KNNmemory{T}, q::AbstractArray, nearestPosAndNegIDs::Tuple) where {T} = memoryLoss(memory, q, nearestPosAndNegIDs...)

function memoryLoss(memory::KNNmemory{T}, normalizedQuery::AbstractArray, nearestPositiveID::Integer, nearestNegativeID::Integer) where {T}    loss = max(dot(normalizedQuery, memory.encoder(memory.M[nearestNegativeID, :])) - dot(normalizedQuery, memory.encoder(memory.M[nearestPositiveID, :])) + memory.α, 0)
end

normalizecolumns(m) = m ./ sqrt.(sum(m .^ 2, dims = 1) .+ eps(eltype(Flux.Tracker.data(m))))

function findInverse(func, invsize, target, precision, learningrate, maxiter)
	loss(x) = sum((func(x) .- target) .^ 2)
	i = 1
	newx = param(rand(Float64, invsize))
	last = newx .+ 1
	opt = ADAM(learningrate)
	while (loss(newx) > precision) & (i < maxiter)
		last = newx
		l = loss(newx)
		Flux.Tracker.back!(l)
		Δ = Flux.Optimise.apply!(opt, newx.data, newx.grad)
        newx.data .-= Δ
		newx.grad .= 0
		i += 1
	end
	return newx
end

"""
    memoryUpdate!(memory, q, v, nearestNeighbourID)
It computes the appropriate update of the memory after a key-value pair was lookedup in it for the key `q` and expected label `v`.
"""
function memoryUpdate!(memory::KNNmemory{T}, q::Vector, v::Integer, nearestNeighbourID::Integer) where {T}
    # If the memory return the correct value for the given key, update the centroid
    if memory.V[nearestNeighbourID] != 1 && memory.V[nearestNeighbourID] == v # TODO: This is a hack to not move anomalies - should be done in a better way!

		target = collect(normalize(Flux.Tracker.data(memory.encoder(q) + memory.encoder(memory.M[nearestNeighbourID, :])))')
		memory.M[nearestNeighbourID, :] = collect(findInverse(memory.encoder, size(memory.M, 2), target', 0.001, 0.01, 1000)')
        memory.A[nearestNeighbourID] = 0

    # If the memory did not return the correct value for the given key, store the key-value pair instead of the oldest element
    else
        oldestElementID = Base.argmax(memory.A .+ rand(1:5))
        memory.M[oldestElementID, :] = Flux.Tracker.data(q)
        memory.V[oldestElementID] = v
        memory.A[oldestElementID] = 0
    end
end

"""
    increaseMemoryAge(memory)
Update the age of all items
"""
function increaseMemoryAge(memory::KNNmemory)
    memory.A .+= 1;
end

"""
    query(memory, q)
Returns the nearest neighbour's value and its confidence level for a given key `q` but does not modify the memory itself.
"""
function query(memory::KNNmemory{T}, q::AbstractArray{T, N} where N) where {T}
    similarity = memory.encodeM(memory.M) * Flux.Tracker.data(memory.encoder(q))
    values = memory.V[Flux.onecold(similarity)]

    function probScorePerQ(index)
        kLargestIDs = collect(partialsortperm(similarity[:, index], 1:memory.k, rev = true))
        probsOfNearestKeys = softmax(similarity[kLargestIDs, index])
        nearestValues = memory.V[kLargestIDs]
        return sum(probsOfNearestKeys[nearestValues .== 1])
    end

    return values, map(probScorePerQ, 1:size(q, 2)) # basicaly returns the nearest value in the memory + sum of probs of anomalies that are in the k-nearest
end

# logc(p, κ) = (p / 2 - 1) * log(κ) - (p / 2) * log(2π) - log(besseli(p / 2 - 1, κ))
logc(p, κ) = (p ./ 2 .- 1) .* log.(κ) .- (p ./ 2) .* log(2π) .- κ .- log.(besselix(p / 2 - 1, κ))


# log likelihood of one sample under the VMF dist with given parameters
# log_vmf(x, μ, κ) = κ * μ' * x .+ log.(c(length(μ), κ))
log_vmf(x, μ, κ) = κ * μ' * x .+ logc(length(μ), κ)

vmf_mix_lkh(x, μs, κ) = vmf_mix_lkh(x, μs, κ, size(μs, 2))
function vmf_mix_lkh(x, μs, κ, μlength::Integer)
    κs = ones(μlength) .* κ # This is quite arbitrary as we don't really know what to use for kappa but it shouldn't matter if it is the same
	l = 0
	for K in 1:μlength
		l += exp.(log_vmf(x, μs[:, K], κs[K]))
	end
	l /= μlength
	return l
end

"""
    prob_query(memory, q)
Returns the nearest neighbour's value and its confidence level for a given key `q` but does not modify the memory itself.
"""
function prob_query(memory::KNNmemory{T}, q::AbstractArray, κ) where {T}
    normq = Flux.Tracker.data(memory.encoder(q))
	encmem = memory.encodeM(memory.M)
    similarity = encmem * normq
    values = memory.V[Flux.onecold(similarity)]

    function probScorePerQ(index)
        kLargestIDs = collect(partialsortperm(similarity[:, index], 1:memory.k, rev = true))
		nearestAnoms = collect(encmem[kLargestIDs, :][memory.V[kLargestIDs] .== 1, :]')
		if length(nearestAnoms) == 0
			return 0
		elseif size(nearestAnoms, 2) == memory.k
			return 1
		end
		nearestNormal = collect(encmem[kLargestIDs, :][memory.V[kLargestIDs] .== 0, :]')
		pxgivena = vmf_mix_lkh(normq[:, index], nearestAnoms, κ)
		pxgivenn = vmf_mix_lkh(normq[:, index], nearestNormal, κ)
		return pxgivena / (pxgivena + pxgivenn)
    end

    return values, map(probScorePerQ, 1:size(q, 2)) # basicaly returns the nearest value in the memory + sum of probs of anomalies that are in the k-nearest
end



"""
    trainQuery!(memory, q, v)
Query 'q' to the memory that does update its content and returns a loss for expected outcome label `v`.
"""
trainQuery!(memory::KNNmemory{T}, q::AbstractArray{T, N} where N, v::Integer) where {T} = trainQuery!(memory, q, [v])

function trainQuery!(memory::KNNmemory{T}, q::AbstractArray{Tt, N} where {Tt, N}, v::Vector{<:Integer}) where {T}
    # Find k nearest neighbours and compute losses
    batchSize = size(q, 2)
    normalizedQuery = Flux.Tracker.data(memory.encoder(q))
    similarity = memory.encodeM(memory.M) * normalizedQuery # computes all similarities of all qs and all keys in the memory at once
    loss::Flux.Tracker.TrackedReal{T} = 0 # loss must be tracked; otherwise flux cannot use it
    nearestNeighbourIDs = zeros(Integer, batchSize)

    for i in 1:batchSize
        kLargestIDs = collect(partialsortperm(similarity[:, i], 1:memory.k, rev = true))
        nearestNeighbourIDs[i] = kLargestIDs[1];
        loss += memoryLoss(memory, normalizedQuery[:, i], findNearestPositiveAndNegative(memory, kLargestIDs, v[i]))
    end

    # Memory update - cannot be done above because we have to compute all losses before changing the memory
    for i in 1:batchSize
		if i % 5 == 1
			println("$i/$batchSize")
		end
        memoryUpdate!(memory, q[:, i], v[i], nearestNeighbourIDs[i])
    end
    increaseMemoryAge(memory)

    return loss / batchSize
end
