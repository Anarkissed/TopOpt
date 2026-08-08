# Does GridapTopOpt's reinitialiser survive HIS grid at all?
# Arm 1 is THEIR OWN example initial level set (`initial_lsf(4,0.2)`), with his
# part nowhere in it — if that NaNs too, the fragility is the library's and not
# the transfer's.
using Gridap, Gridap.Geometry, GridapTopOpt, JSON, Printf
P=JSON.parsefile("problem/problem.json")
NX,NY,NZ = P["nx"],P["ny"],P["nz"]; H=P["spacing_mm"]; OX,OY,OZ=P["origin_mm"]
C = parse(Int, get(ENV,"COARSEN","1"))
NX,NY,NZ = cld(NX,C),cld(NY,C),cld(NZ,C); H=H*C
dom=(OX,OX+NX*H,OY,OY+NY*H,OZ,OZ+NZ*H)
model=CartesianDiscreteModel(dom,(NX,NY,NZ))
V_φ=TestFESpace(model,ReferenceFE(lagrangian,Float64,1))
el_Δ=get_el_Δ(model)
@printf("grid %d x %d x %d  h=%.6f  el_Δ=%s\n",NX,NY,NZ,H,string(el_Δ))
seed=initial_lsf(4,0.2)
for (name, γr, tol) in (("their-example-defaults", 0.5, 1/5/minimum((NX,NY,NZ))),
                        ("gamma-0.1",              0.1, 1/5/minimum((NX,NY,NZ))),
                        ("tol-loose-1e-2",         0.5, 1e-2))
  reinit=FiniteDifferenceReinitialiser(FirstOrderStencil(3,Float64),model,V_φ;tol,γ_reinit=γr)
  φ=interpolate(seed,V_φ); v0=copy(get_free_dof_values(φ))
  ok=true; msg=""
  try
    GridapTopOpt.reinit!(reinit,φ)
  catch e
    ok=false; msg=sprint(showerror,e)[1:min(60,end)]
  end
  v=get_free_dof_values(φ)
  @printf("%-24s γ_reinit=%.2f tol=%.5f : before[%.4f,%.4f] NaN=%d %s\n",
    name,γr,tol,minimum(v0),maximum(v0),count(isnan,v), ok ? "" : ("THREW: "*msg))
end
