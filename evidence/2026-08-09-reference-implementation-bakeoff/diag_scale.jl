using Gridap, Gridap.Geometry, GridapTopOpt, JSON, Printf
P=JSON.parsefile("problem/problem.json")
NX,NY,NZ=P["nx"],P["ny"],P["nz"]; H=P["spacing_mm"]; OX,OY,OZ=P["origin_mm"]
n0=NX*NY*NZ
solid=read!("problem/solid.u8",Vector{UInt8}(undef,n0)); mask=read!("problem/mask.u8",Vector{UInt8}(undef,n0))
vidx(i,j,k)=(k*NY+j)*NX+i+1
dom=(OX,OX+NX*H,OY,OY+NY*H,OZ,OZ+NZ*H)
model=CartesianDiscreteModel(dom,(NX,NY,NZ))
V_φ=TestFESpace(model,ReferenceFE(lagrangian,Float64,1))
tol=1/5/minimum((NX,NY,NZ))
# ★ initial_lsf(ξ,a) is -1/4*prod(cos(ξ*π*x)) - a/4, so its holes repeat with
# period 2/ξ IN MODEL UNITS. Their examples run on a 2x1x1 domain where ξ=4 gives
# 4 holes across; his part is 218 mm across, where ξ=4 gives a 0.5 mm period —
# ALIASED, four times finer than his 1.705 mm voxel. The seeding has to be
# expressed in his units: ξ = 2/(k*H) puts a hole every k voxels.
seedk(k,amp) = (f = initial_lsf(2/(k*H), 0.2); x -> amp*f(x))
seed = seedk(8, 1.0)
function bfs(t)
  D=fill(10_000,n0); q=Int[]
  for v in eachindex(t); t[v] && (D[v]=0; push!(q,v)); end
  h=1
  while h<=length(q)
    v=q[h];h+=1; kk,r=divrem(v-1,NX*NY); jj,ii=divrem(r,NX)
    for (di,dj,dk) in ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1))
      a,b,c=ii+di,jj+dj,kk+dk; (a<0||b<0||c<0||a>=NX||b>=NY||c>=NZ)&&continue
      w=vidx(a,b,c); D[w]>D[v]+1 && (D[w]=D[v]+1; push!(q,w))
    end
  end; D
end
inside=falses(n0)
for k in 0:NZ-1,j in 0:NY-1,i in 0:NX-1
  v=vidx(i,j,k)
  inside[v]= solid[v]==0 ? false : (mask[v]==1 ? true :
    seed(VectorValue(OX+(i+0.5)*H,OY+(j+0.5)*H,OZ+(k+0.5)*H))<0)
end
dv=bfs(.!inside); ds=bfs(inside)
cell(f)= x->begin
  i=clamp(floor(Int,(x[1]-OX)/H),0,NX-1); j=clamp(floor(Int,(x[2]-OY)/H),0,NY-1)
  k=clamp(floor(Int,(x[3]-OZ)/H),0,NZ-1); f(vidx(i,j,k),x)
end
hybrid2(band,sd) = cell((v,x)-> solid[v]==0 ?  clamp((ds[v]-0.5)*H,0,band*H) :
                                (mask[v]==1 ? -clamp((dv[v]-0.5)*H,0,band*H) : sd(x)))
arms = [
 ("holes  6h, amp H",  hybrid2(5.0, seedk(6, H))),
 ("holes  8h, amp H",  hybrid2(5.0, seedk(8, H))),
 ("holes  8h, amp 2H", hybrid2(5.0, seedk(8, 2H))),
 ("holes 12h, amp H",  hybrid2(5.0, seedk(12, H))),
]
reinit=FiniteDifferenceReinitialiser(FirstOrderStencil(3,Float64),model,V_φ;tol,γ_reinit=0.5)
for (name,f) in arms
  φ=interpolate(f,V_φ); v0=copy(get_free_dof_values(φ))
  GridapTopOpt.reinit!(reinit,φ); v=get_free_dof_values(φ)
  frac = count(<(0), v0) / length(v0)
  @printf("%-22s before[%8.4f,%8.4f] init-solid %.3f  NaN=%7d  after[%s]\n", name,
    minimum(v0),maximum(v0),frac,count(isnan,v),
    any(isnan,v) ? "  NaN, NaN" : @sprintf("%8.3f,%8.3f",minimum(v),maximum(v)))
end
