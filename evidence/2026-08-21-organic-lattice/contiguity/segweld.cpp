// Do struts touch that the NODE-based weld never sees?
// build_beam_network welds node pairs within r_a+r_b. Two struts can cross with the
// closest approach mid-SEGMENT on both, where neither has a node: fused in print,
// separate in the model. Count the components under each rule.
#include "topopt/beam_network.hpp"
#include <cstdio>
#include <cmath>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <functional>
using topopt::Vec3;
static double seg_seg_d2(const Vec3&p1,const Vec3&q1,const Vec3&p2,const Vec3&q2){
  const Vec3 d1{q1.x-p1.x,q1.y-p1.y,q1.z-p1.z}, d2{q2.x-p2.x,q2.y-p2.y,q2.z-p2.z};
  const Vec3 r{p1.x-p2.x,p1.y-p2.y,p1.z-p2.z};
  const double a=d1.x*d1.x+d1.y*d1.y+d1.z*d1.z, e=d2.x*d2.x+d2.y*d2.y+d2.z*d2.z;
  const double f=d2.x*r.x+d2.y*r.y+d2.z*r.z; double s=0,t=0;
  const double c=d1.x*r.x+d1.y*r.y+d1.z*r.z;
  const double b=d1.x*d2.x+d1.y*d2.y+d1.z*d2.z, den=a*e-b*b;
  if(den>1e-12) s=std::min(1.0,std::max(0.0,(b*f-c*e)/den));
  t=(b*s+f)/(e>1e-12?e:1.0); t=std::min(1.0,std::max(0.0,t));
  s=(b*t-c)/(a>1e-12?a:1.0); s=std::min(1.0,std::max(0.0,s));
  const double cx=p1.x+d1.x*s-(p2.x+d2.x*t), cy=p1.y+d1.y*s-(p2.y+d2.y*t),
               cz=p1.z+d1.z*s-(p2.z+d2.z*t);
  return cx*cx+cy*cy+cz*cz;
}
int main(int argc,char**argv){
  std::printf("%-10s %10s %14s %14s   %s\n","cell","segments","comps (node)","comps (segment)","bridges node -> segment");
  for(int a=1;a<argc;a+=2){
    const std::string label=argv[a],path=argv[a+1];
    std::vector<topopt::BeamSegment> segs;
    { std::ifstream f(path); std::string ln;
      while(std::getline(f,ln)){ std::istringstream is(ln); std::string t; is>>t;
        if(t!="SEG") continue; topopt::BeamSegment s; double r;
        is>>s.a.x>>s.a.y>>s.a.z>>s.b.x>>s.b.y>>s.b.z>>r; s.radius_mm=r; segs.push_back(s);} }
    if(segs.empty()){std::printf("%-10s (none)\n",label.c_str());continue;}
    const topopt::BeamNetwork net=topopt::build_beam_network(segs);
    const std::size_t NV=net.node_count();
    std::vector<int> par(NV); for(std::size_t i=0;i<NV;++i)par[i]=int(i);
    std::function<int(int)> fnd=[&](int x){while(par[x]!=x){par[x]=par[par[x]];x=par[x];}return x;};
    auto uni=[&](int x,int y){x=fnd(x);y=fnd(y);if(x!=y)par[x>y?x:y]=x<y?x:y;};
    for(const auto&m:net.members) uni(m.node_a,m.node_b);
    std::map<int,int> c1; for(const auto&m:net.members)++c1[fnd(m.node_a)];
    const std::vector<char> br1=topopt::beam_network_bridges(net);
    std::size_t nb1=0; for(char c:br1)nb1+=c?1u:0u;
    // now also unite members whose SEGMENTS come within r_a + r_b
    double rmax=0; for(const auto&m:net.members)rmax=std::max(rmax,m.radius_mm);
    const double cell=std::max(1e-6,4*rmax);
    std::unordered_map<long long,std::vector<int>> grid;
    auto key=[&](long long i,long long j,long long k){return (i*73856093LL)^(j*19349663LL)^(k*83492791LL);};
    for(std::size_t m=0;m<net.member_count();++m){
      const Vec3&p=net.nodes[net.members[m].node_a];const Vec3&q=net.nodes[net.members[m].node_b];
      for(double t=0;t<=1.0001;t+=0.5){
        const double x=p.x+(q.x-p.x)*t,y=p.y+(q.y-p.y)*t,z=p.z+(q.z-p.z)*t;
        grid[key((long long)std::floor(x/cell),(long long)std::floor(y/cell),(long long)std::floor(z/cell))].push_back(int(m));}}
    std::size_t extra=0;
    for(std::size_t m=0;m<net.member_count();++m){
      const auto&M=net.members[m];
      const Vec3&p=net.nodes[M.node_a];const Vec3&q=net.nodes[M.node_b];
      const long long i0=(long long)std::floor(std::min(p.x,q.x)/cell),i1=(long long)std::floor(std::max(p.x,q.x)/cell);
      const long long j0=(long long)std::floor(std::min(p.y,q.y)/cell),j1=(long long)std::floor(std::max(p.y,q.y)/cell);
      const long long k0=(long long)std::floor(std::min(p.z,q.z)/cell),k1=(long long)std::floor(std::max(p.z,q.z)/cell);
      for(long long i=i0-1;i<=i1+1;++i)for(long long j=j0-1;j<=j1+1;++j)for(long long k=k0-1;k<=k1+1;++k){
        auto it=grid.find(key(i,j,k)); if(it==grid.end())continue;
        for(int n2:it->second){ if(std::size_t(n2)<=m)continue;
          const auto&N=net.members[n2];
          if(M.node_a==N.node_a||M.node_a==N.node_b||M.node_b==N.node_a||M.node_b==N.node_b)continue;
          if(fnd(M.node_a)==fnd(N.node_a))continue;              // already one piece
          const double lim=M.radius_mm+N.radius_mm;
          if(seg_seg_d2(p,q,net.nodes[N.node_a],net.nodes[N.node_b])<=lim*lim){ uni(M.node_a,N.node_a); ++extra; }}}}
    std::map<int,int> c2; for(const auto&m:net.members)++c2[fnd(m.node_a)];
    std::printf("%-10s %10zu %14zu %14zu   %.1f%% -> (welds added %zu)\n",label.c_str(),
                net.member_count(),c1.size(),c2.size(),100.0*double(nb1)/double(br1.size()),extra);
  }
  return 0;
}
