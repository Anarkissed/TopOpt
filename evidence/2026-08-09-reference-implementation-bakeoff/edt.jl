# Exact Euclidean distance transform, Felzenszwalb & Huttenlocher (2012),
# "Distance Transforms of Sampled Functions", separable 1-D lower envelope.
# Used ONLY to initialise a level set: the 6-neighbour BFS distance this
# replaces is an L1 distance whose gradient is wrong by up to 73% on diagonals,
# and their first-order upwind reinitialiser assumes |∇φ| ≈ 1.
module EDT
export edt_signed
function dt1d!(f::Vector{Float64}, d::Vector{Float64}, v::Vector{Int}, z::Vector{Float64})
    n = length(f); k = 1; v[1] = 1; z[1] = -Inf; z[2] = Inf
    for q in 2:n
        s = ((f[q] + q*q) - (f[v[k]] + v[k]*v[k])) / (2q - 2v[k])
        while s <= z[k]
            k -= 1
            s = ((f[q] + q*q) - (f[v[k]] + v[k]*v[k])) / (2q - 2v[k])
        end
        k += 1; v[k] = q; z[k] = s; z[k+1] = Inf
    end
    k = 1
    for q in 1:n
        while z[k+1] < q; k += 1; end
        d[q] = (q - v[k])^2 + f[v[k]]
    end
    return d
end
"squared EDT of the set where mask is TRUE, in cell units, on an nx*ny*nz grid"
function sqedt(mask::AbstractVector{Bool}, nx::Int, ny::Int, nz::Int)
    BIG = 1e20
    g = Vector{Float64}(undef, nx*ny*nz)
    @inbounds for i in eachindex(mask); g[i] = mask[i] ? 0.0 : BIG; end
    idx(i,j,k) = (k*ny + j)*nx + i + 1
    nmax = max(nx,ny,nz)
    f = Vector{Float64}(undef,nmax); d = Vector{Float64}(undef,nmax)
    v = Vector{Int}(undef,nmax+1); z = Vector{Float64}(undef,nmax+2)
    @inbounds for k in 0:nz-1, j in 0:ny-1                    # along x
        for i in 0:nx-1; f[i+1] = g[idx(i,j,k)]; end
        dt1d!(view(f,1:nx) |> collect, d, v, z)
        for i in 0:nx-1; g[idx(i,j,k)] = d[i+1]; end
    end
    @inbounds for k in 0:nz-1, i in 0:nx-1                    # along y
        for j in 0:ny-1; f[j+1] = g[idx(i,j,k)]; end
        dt1d!(view(f,1:ny) |> collect, d, v, z)
        for j in 0:ny-1; g[idx(i,j,k)] = d[j+1]; end
    end
    @inbounds for j in 0:ny-1, i in 0:nx-1                    # along z
        for k in 0:nz-1; f[k+1] = g[idx(i,j,k)]; end
        dt1d!(view(f,1:nz) |> collect, d, v, z)
        for k in 0:nz-1; g[idx(i,j,k)] = d[k+1]; end
    end
    return g
end
"signed EDT in MODEL UNITS: negative inside, +0 outside, band-limited"
function edt_signed(inside::AbstractVector{Bool}, nx, ny, nz, h::Float64, band::Float64)
    din  = sqrt.(sqedt(.!inside, nx, ny, nz))   # distance to the nearest outside cell
    dout = sqrt.(sqedt(  inside, nx, ny, nz))   # distance to the nearest inside cell
    φ = Vector{Float64}(undef, length(inside))
    @inbounds for v in eachindex(inside)
        φ[v] = clamp(inside[v] ? -(din[v] - 0.5) : (dout[v] - 0.5), -band, band) * h
    end
    return φ
end
end
