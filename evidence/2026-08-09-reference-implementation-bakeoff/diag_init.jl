# Which initial level set survives GridapTopOpt's own reinitialiser?
using Gridap, GridapTopOpt, JSON, Printf
P = JSON.parsefile("problem/problem.json")
C = 4
NX0,NY0,NZ0 = P["nx"],P["ny"],P["nz"]; H0=P["spacing_mm"]; OX,OY,OZ = P["origin_mm"]
NX,NY,NZ = cld(NX0,C),cld(NY0,C),cld(NZ0,C); H = H0*C
n0=NX0*NY0*NZ0
solid0=read!("problem/solid.u8",Vector{UInt8}(undef,n0)); mask0=read!("problem/mask.u8",Vector{UInt8}(undef,n0))
vidx0(i,j,k)=(k*NY0+j)*NX0+i+1; vidx(i,j,k)=(k*NY+j)*NX+i+1
solid=zeros(UInt8,NX*NY*NZ); mask=fill(UInt8(2),NX*NY*NZ)
for k in 0:NZ-1,j in 0:NY-1,i in 0:NX-1
  s=UInt8(0);m=UInt8(2)
  for dk in 0:C-1,dj in 0:C-1,di in 0:C-1
    ii,jj,kk=i*C+di,j*C+dj,k*C+dk; (ii>=NX0||jj>=NY0||kk>=NZ0)&&continue
    v=vidx0(ii,jj,kk); solid0[v]!=0 && (s=max(s,solid0[v]))
    mask0[v]==1 && (m=UInt8(1)); mask0[v]==0 && m!=1 && (m=UInt8(0))
  end
  solid[vidx(i,j,k)]=s; mask[vidx(i,j,k)] = s==0 ? UInt8(2) : m
end
dom=(OX,OX+NX*H,OY,OY+NY*H,OZ,OZ+NZ*H)
model=CartesianDiscreteModel(dom,(NX,NY,NZ))
V_φ=TestFESpace(model,ReferenceFE(lagrangian,Float64,1))
tol=1/5/minimum((NX,NY,NZ))
reinit=FiniteDifferenceReinitialiser(FirstOrderStencil(3,Float64),model,V_φ;tol,γ_reinit=0.5)
seed=initial_lsf(4,0.2)

function bfs(target)
  D=fill(10_000, NX*NY*NZ); q=Int[]
  for v in eachindex(target); target[v] && (D[v]=0; push!(q,v)); end
  h=1
  while h<=length(q)
    v=q[h];h+=1; kk,r=divrem(v-1,NX*NY); jj,ii=divrem(r,NX)
    for (di,dj,dk) in ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1))
      a,b,c=ii+di,jj+dj,kk+dk
      (a<0||b<0||c<0||a>=NX||b>=NY||c>=NZ)&&continue
      w=vidx(a,b,c); D[w]>D[v]+1 && (D[w]=D[v]+1; push!(q,w))
    end
  end; D
end
inside=falses(NX*NY*NZ)
for k in 0:NZ-1,j in 0:NY-1,i in 0:NX-1
  v=vidx(i,j,k)
  inside[v] = solid[v]==0 ? false : (mask[v]==1 ? true :
     seed(VectorValue(OX+(i+0.5)*H,OY+(j+0.5)*H,OZ+(k+0.5)*H))<0)
end
dv=bfs(.!inside); ds=bfs(inside)
sdf=[ (inside[v] ? -(dv[v]-0.5) : (ds[v]-0.5))*H for v in eachindex(inside) ]
cellat(f)= x->begin
  i=clamp(floor(Int,(x[1]-OX)/H),0,NX-1); j=clamp(floor(Int,(x[2]-OY)/H),0,NY-1)
  k=clamp(floor(Int,(x[3]-OZ)/H),0,NZ-1); f(vidx(i,j,k),x)
end
cands = Dict(
 "A_step_pm_h"    => cellat((v,x)-> solid[v]==0 ?  H : (mask[v]==1 ? -H : 4H*seed(x))),
 "B_bfs_band5"    => cellat((v,x)-> clamp(sdf[v], -5H, 5H)),
 "C_bfs_band2"    => cellat((v,x)-> clamp(sdf[v], -2H, 2H)),
 "D_partsdf_seed" => cellat((v,x)-> solid[v]==0 ? clamp((ds[v]-0.5)*H,0,5H) :
                                    (mask[v]==1 ? -clamp((dv[v]-0.5)*H,0,5H) : 4H*seed(x))),
)
for k in sort(collect(keys(cands)))
  φ=interpolate(cands[k],V_φ); v0=copy(get_free_dof_values(φ))
  GridapTopOpt.reinit!(reinit,φ); v=get_free_dof_values(φ)
  @printf("%-16s before [%8.3f,%8.3f]  after [%9.3f,%9.3f]  NaN=%6d  Inf=%d\n",
    k, minimum(v0),maximum(v0),
    (any(isnan,v) ? NaN : minimum(v)), (any(isnan,v) ? NaN : maximum(v)),
    count(isnan,v), count(isinf,v))
end
