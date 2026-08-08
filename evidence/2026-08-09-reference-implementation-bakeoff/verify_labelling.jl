# S2's LABELLING CONTROL. `his_part_ALM.jl` cannot call GridapTopOpt's own
# `update_labels!` at his resolution — its 3-D branch is O(n^2) in the number of
# marked vertices and does not return when ~480,000 of his 491,232 nodes are
# marked. It uses `tag_vertices!` instead, which does the VERTEX half and skips
# the edge/face/cell promotion.
#
# THIS SCRIPT IS THE PROOF THAT THE SUBSTITUTION IS EXACT for what it is used
# for. On HIS problem, coarsened 4x so THEIR function is affordable, it builds
# the same three tags both ways and compares the FE spaces that come out:
# free dofs, Dirichlet dofs, and the Dirichlet dof set itself.
using Gridap, Gridap.Geometry, GridapTopOpt, JSON, Printf
P = JSON.parsefile("problem/problem.json")
C = parse(Int, get(ENV, "COARSEN", "4"))
NX0,NY0,NZ0 = P["nx"],P["ny"],P["nz"]; H0=P["spacing_mm"]; OX,OY,OZ=P["origin_mm"]
NX,NY,NZ = cld(NX0,C),cld(NY0,C),cld(NZ0,C); H=H0*C
n0=NX0*NY0*NZ0
solid0=read!("problem/solid.u8",Vector{UInt8}(undef,n0)); mask0=read!("problem/mask.u8",Vector{UInt8}(undef,n0))
vidx0(i,j,k)=(k*NY0+j)*NX0+i+1; vidx(i,j,k)=(k*NY+j)*NX+i+1
NNX0,NNY0,NNZ0 = NX0+1,NY0+1,NZ0+1; NNX,NNY,NNZ = NX+1,NY+1,NZ+1
nidx(i,j,k)=(k*NNY+j)*NNX+i+1
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
anchor0=falses(NNX0*NNY0*NNZ0)
let raw=read!("problem/dirichlet.i32",Vector{Int32}(undef,2*P["dirichlet_dofs"]))
  for e in 1:P["dirichlet_dofs"]; anchor0[raw[2*e-1]+1]=true; end
end
anchor=falses(NNX*NNY*NNZ)
for k in 0:NNZ-1,j in 0:NNY-1,i in 0:NNX-1
  ii,jj,kk=min(i*C,NNX0-1),min(j*C,NNY0-1),min(k*C,NNZ0-1)
  anchor[nidx(i,j,k)]=anchor0[(kk*NNY0+jj)*NNX0+ii+1]
end
movable=falses(NNX*NNY*NNZ)
for k in 0:NZ-1,j in 0:NY-1,i in 0:NX-1
  mask[vidx(i,j,k)]==0 || continue
  for dk in 0:1,dj in 0:1,di in 0:1; movable[nidx(i+di,j+dj,k+dk)]=true; end
end
node_ijk(x)=(clamp(round(Int,(x[1]-OX)/H),0,NX), clamp(round(Int,(x[2]-OY)/H),0,NY),
             clamp(round(Int,(x[3]-OZ)/H),0,NZ))
at_anchor(x)=anchor[nidx(node_ijk(x)...)]
at_pinned(x)=!movable[nidx(node_ijk(x)...)]

function tag_vertices!(model,e,mask,name)
  labels=get_face_labeling(model); entity=maximum(labels.d_to_dface_to_entity[end])+e
  vtx=findall(mask); labels.d_to_dface_to_entity[1][vtx] .= entity
  add_tag!(labels,name,[entity]); length(vtx)
end

dom=(OX,OX+NX*H,OY,OY+NY*H,OZ,OZ+NZ*H)
reffe=ReferenceFE(lagrangian,VectorValue{3,Float64},1)
reffe_s=ReferenceFE(lagrangian,Float64,1)

function build(which)
  model=CartesianDiscreteModel(dom,(NX,NY,NZ))
  fA(x)=at_anchor(x) && !at_pinned(x); fP(x)=at_pinned(x) && !at_anchor(x)
  fB(x)=at_anchor(x) &&  at_pinned(x)
  t0=time()
  if which==:theirs
    update_labels!(1,model,fA,"AnchorOnly"); update_labels!(2,model,fP,"PinOnly")
    update_labels!(3,model,fB,"AnchorPin")
  else
    vc=Gridap.Geometry.get_vertex_coordinates(get_grid_topology(model))
    a=Bool[at_anchor(x) for x in vc]; p=Bool[at_pinned(x) for x in vc]
    tag_vertices!(model,1,a .& .!p,"AnchorOnly"); tag_vertices!(model,2,p .& .!a,"PinOnly")
    tag_vertices!(model,3,a .& p,"AnchorPin")
  end
  el=time()-t0
  labels=get_face_labeling(model)
  add_tag_from_tags!(labels,"Gamma_D",["AnchorOnly","AnchorPin"])
  add_tag_from_tags!(labels,"Gamma_Pin",["PinOnly","AnchorPin"])
  V=TestFESpace(model,reffe;dirichlet_tags=["Gamma_D"])
  Vr=TestFESpace(model,reffe_s;dirichlet_tags=["Gamma_Pin"])
  (el, num_free_dofs(V), num_dirichlet_dofs(V), num_free_dofs(Vr), num_dirichlet_dofs(Vr),
   copy(V.metadata.free_dof_to_node), copy(Vr.metadata.free_dof_to_node))
end

t = build(:theirs); m = build(:mine)
@printf("grid %d x %d x %d (coarsen %d)\n", NX,NY,NZ,C)
@printf("%-8s labelling %8.3f s  V free %7d diri %6d   V_reg free %7d diri %7d\n",
        "THEIRS", t[1], t[2], t[3], t[4], t[5])
@printf("%-8s labelling %8.3f s  V free %7d diri %6d   V_reg free %7d diri %7d\n",
        "MINE",   m[1], m[2], m[3], m[4], m[5])
ok = t[2:5] == m[2:5] && t[6] == m[6] && t[7] == m[7]
@printf("free-dof->node maps identical: V %s   V_reg %s\n",
        t[6]==m[6] ? "YES" : "NO", t[7]==m[7] ? "YES" : "NO")
println(ok ? "IDENTICAL — the substitution is exact for order-1 dof selection" :
             "DIFFERENT — the substitution is NOT exact")
@printf("speedup %.1fx\n", t[1]/max(m[1],1e-9))
exit(ok ? 0 : 1)
