using Gridap, Gridap.Geometry, GridapTopOpt, JSON, Printf
include("edt.jl"); using .EDT
P=JSON.parsefile("problem/problem.json")
NX,NY,NZ=P["nx"],P["ny"],P["nz"]; H=P["spacing_mm"]; OX,OY,OZ=P["origin_mm"]
n0=NX*NY*NZ
solid=read!("problem/solid.u8",Vector{UInt8}(undef,n0)); mask=read!("problem/mask.u8",Vector{UInt8}(undef,n0))
vidx(i,j,k)=(k*NY+j)*NX+i+1
dom=(OX,OX+NX*H,OY,OY+NY*H,OZ,OZ+NZ*H)
model=CartesianDiscreteModel(dom,(NX,NY,NZ))
V_φ=TestFESpace(model,ReferenceFE(lagrangian,Float64,1))
tol=1/5/minimum((NX,NY,NZ))
reinit=FiniteDifferenceReinitialiser(FirstOrderStencil(3,Float64),model,V_φ;tol,γ_reinit=0.5)
seedf = let f=initial_lsf(2/(8H),0.2); x->H*f(x) end
inside_part = BitVector(undef,n0)
for k in 0:NZ-1,j in 0:NY-1,i in 0:NX-1
  v=vidx(i,j,k)
  inside_part[v] = solid[v]==0 ? false : (mask[v]==1 ? true :
    seedf(VectorValue(OX+(i+0.5)*H,OY+(j+0.5)*H,OZ+(k+0.5)*H))<0)
end
inside_full = BitVector(solid .!= 0)     # the WHOLE part, no seeding: the SIMP-like case
arms = Dict("EDT part+seed" => (inside_part, 5.0),
            "EDT whole part (no seed)" => (inside_full, 5.0),
            "EDT whole part band 3"    => (inside_full, 3.0))
for k in sort(collect(keys(arms)))
  ins,band = arms[k]
  t0=time(); φc = edt_signed(ins, NX,NY,NZ, H, band); te=time()-t0
  f(x)=begin
    i=clamp(floor(Int,(x[1]-OX)/H),0,NX-1); j=clamp(floor(Int,(x[2]-OY)/H),0,NY-1)
    kk=clamp(floor(Int,(x[3]-OZ)/H),0,NZ-1); φc[vidx(i,j,kk)]
  end
  φ=interpolate(f,V_φ); v0=copy(get_free_dof_values(φ))
  GridapTopOpt.reinit!(reinit,φ); v=get_free_dof_values(φ)
  @printf("%-26s EDT %.2fs before[%7.3f,%7.3f] NaN=%6d after[%s]\n", k, te,
    minimum(v0),maximum(v0),count(isnan,v),
    any(isnan,v) ? " NaN" : @sprintf("%7.3f,%7.3f",minimum(v),maximum(v)))
end
