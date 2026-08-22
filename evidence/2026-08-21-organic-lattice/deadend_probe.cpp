// ★ THE DEAD-END CENSUS, ON A SHIPPED STL AND NOTHING ELSE.
// Two stages, because the first one alone over-flags (269 on a coupon that PRINTED):
//   1. candidates — vertices whose neighbourhood inside R is one-sided along the local
//      member axis (a cheap filter, deliberately loose)
//   2. verdict    — count how many MEMBERS cross out of a ball of radius Rb about the
//      candidate. 1 limb = a DEAD END. 2 = mid-member. 3+ = a junction.
// Only stage 2 is reported as a defect. Stage 1 exists to keep stage 2 affordable.
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <map>
#include <set>
#include <array>
#include <vector>
#include <algorithm>
struct V{double x,y,z;};
int main(int argc,char**argv){
  const double R=1.6, Rb=(argc>2?atof(argv[2]):2.0);
  FILE*f=fopen(argv[1],"rb"); if(!f){printf("no file %s\n",argv[1]);return 1;}
  char h[80]; if(fread(h,1,80,f)!=80)return 1; uint32_t n; if(fread(&n,4,1,f)!=1)return 1;
  std::set<std::array<float,3>> uq;
  for(uint32_t i=0;i<n;i++){float b[12];uint16_t a;
    if(fread(b,4,12,f)!=12)break; if(fread(&a,2,1,f)!=1)break;
    for(int k=0;k<3;k++) uq.insert({b[3+3*k],b[4+3*k],b[5+3*k]});}
  fclose(f);
  std::vector<V> P; for(auto&u:uq) P.push_back({u[0],u[1],u[2]});
  double zmin=1e30; for(auto&p:P) zmin=std::min(zmin,p.z);
  auto grid=[&](double c){ std::map<std::array<long long,3>,std::vector<int>> g;
    for(int i=0;i<(int)P.size();i++)
      g[{(long long)std::floor(P[i].x/c),(long long)std::floor(P[i].y/c),(long long)std::floor(P[i].z/c)}].push_back(i);
    return g; };
  auto g1=grid(R);
  std::vector<int> cand;
  for(int i=0;i<(int)P.size();i++){
    if(P[i].z-zmin<=0.30) continue;
    std::array<long long,3> k0{(long long)std::floor(P[i].x/R),(long long)std::floor(P[i].y/R),(long long)std::floor(P[i].z/R)};
    std::vector<V> nb;
    for(long long dz=-1;dz<=1;dz++)for(long long dy=-1;dy<=1;dy++)for(long long dx=-1;dx<=1;dx++){
      auto it=g1.find({k0[0]+dx,k0[1]+dy,k0[2]+dz}); if(it==g1.end())continue;
      for(int j:it->second){ if(j==i)continue; V d{P[j].x-P[i].x,P[j].y-P[i].y,P[j].z-P[i].z};
        if(d.x*d.x+d.y*d.y+d.z*d.z<=R*R) nb.push_back(d);} }
    if(nb.size()<20) continue;
    double c[6]={0,0,0,0,0,0};
    for(auto&d:nb){c[0]+=d.x*d.x;c[1]+=d.x*d.y;c[2]+=d.x*d.z;c[3]+=d.y*d.y;c[4]+=d.y*d.z;c[5]+=d.z*d.z;}
    V u{1,0.3,0.7};
    for(int t=0;t<40;t++){V w{c[0]*u.x+c[1]*u.y+c[2]*u.z,c[1]*u.x+c[3]*u.y+c[4]*u.z,c[2]*u.x+c[4]*u.y+c[5]*u.z};
      double L=std::sqrt(w.x*w.x+w.y*w.y+w.z*w.z); if(L<1e-18)break; u={w.x/L,w.y/L,w.z/L};}
    double lo=0,hi=0; for(auto&d:nb){double t=d.x*u.x+d.y*u.y+d.z*u.z; lo=std::min(lo,t); hi=std::max(hi,t);}
    if(std::max(-lo,hi)>=0.9*R && std::min(-lo,hi)<=0.30) cand.push_back(i);
  }
  // cluster candidates into distinct ends
  std::vector<char> used(cand.size(),0); std::vector<V> ends;
  for(size_t a=0;a<cand.size();a++){ if(used[a])continue; used[a]=1; std::vector<int> st{(int)a}; V s=P[cand[a]]; int m=1;
    while(!st.empty()){int cc=st.back();st.pop_back();
      for(size_t b=0;b<cand.size();b++){ if(used[b])continue;
        double dx=P[cand[b]].x-P[cand[cc]].x,dy=P[cand[b]].y-P[cand[cc]].y,dz=P[cand[b]].z-P[cand[cc]].z;
        if(dx*dx+dy*dy+dz*dz<=(1.2*R)*(1.2*R)){used[b]=1;st.push_back((int)b);
          s.x+=P[cand[b]].x;s.y+=P[cand[b]].y;s.z+=P[cand[b]].z;m++;} } }
    ends.push_back({s.x/m,s.y/m,s.z/m}); }
  auto g2=grid(Rb);
  int dead=0;
  for(auto&c:ends){
    std::vector<V> shell;
    std::array<long long,3> k0{(long long)std::floor(c.x/Rb),(long long)std::floor(c.y/Rb),(long long)std::floor(c.z/Rb)};
    for(long long dz=-2;dz<=2;dz++)for(long long dy=-2;dy<=2;dy++)for(long long dx=-2;dx<=2;dx++){
      auto it=g2.find({k0[0]+dx,k0[1]+dy,k0[2]+dz}); if(it==g2.end())continue;
      for(int j:it->second){ double d=std::sqrt((P[j].x-c.x)*(P[j].x-c.x)+(P[j].y-c.y)*(P[j].y-c.y)+(P[j].z-c.z)*(P[j].z-c.z));
        if(d>=Rb-0.35&&d<=Rb+0.15) shell.push_back(P[j]); } }
    std::vector<char> u2(shell.size(),0); int limbs=0;
    for(size_t a=0;a<shell.size();a++){ if(u2[a])continue; u2[a]=1; int m=1; std::vector<int> st{(int)a};
      while(!st.empty()){int cc=st.back();st.pop_back();
        for(size_t b=0;b<shell.size();b++){ if(u2[b])continue;
          double dx=shell[b].x-shell[cc].x,dy=shell[b].y-shell[cc].y,dz=shell[b].z-shell[cc].z;
          if(dx*dx+dy*dy+dz*dz<=0.45*0.45){u2[b]=1;st.push_back((int)b);m++;} } }
      if(m>=6) limbs++; }
    if(limbs<=1){ dead++; if(getenv("DUMP")) printf("   DEAD (%6.2f,%6.2f,%6.2f)\n",c.x,c.y,c.z); }
  }
  printf("%-56s verts %7zu   candidates %4zu   ★ DEAD ENDS %4d   (%.1f per 100k verts)\n",
         argv[1],P.size(),ends.size(),dead,dead*100000.0/P.size());
  return 0;
}
