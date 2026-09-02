#include "topopt/beam_network.hpp"
#include <cstdio>
#include <cmath>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <functional>
int main(int argc,char**argv){
  for(int a=1;a<argc;a+=2){
    const std::string label=argv[a],path=argv[a+1];
    std::vector<topopt::BeamSegment> segs;
    { std::ifstream f(path); std::string ln;
      while(std::getline(f,ln)){ std::istringstream is(ln); std::string t; is>>t;
        if(t!="SEG")continue; topopt::BeamSegment s; double r;
        is>>s.a.x>>s.a.y>>s.a.z>>s.b.x>>s.b.y>>s.b.z>>r; s.radius_mm=r; segs.push_back(s);} }
    if(segs.empty())continue;
    const topopt::BeamNetwork net=topopt::build_beam_network(segs);
    std::vector<int> par(net.node_count());
    for(std::size_t i=0;i<par.size();++i)par[i]=int(i);
    std::function<int(int)> fnd=[&](int x){while(par[x]!=x){par[x]=par[par[x]];x=par[x];}return x;};
    for(const auto&m:net.members){const int x=fnd(m.node_a),y=fnd(m.node_b);if(x!=y)par[x>y?x:y]=x<y?x:y;}
    std::map<int,int> cnt; std::map<int,double> ymin,ymax;
    for(const auto&m:net.members){const int r=fnd(m.node_a);++cnt[r];
      const double y1=net.nodes[m.node_a].y,y2=net.nodes[m.node_b].y;
      if(!ymin.count(r)){ymin[r]=std::min(y1,y2);ymax[r]=std::max(y1,y2);}
      ymin[r]=std::min(ymin[r],std::min(y1,y2)); ymax[r]=std::max(ymax[r],std::max(y1,y2));}
    std::vector<std::pair<int,int>> v; for(auto&kv:cnt)v.push_back({kv.second,kv.first});
    std::sort(v.rbegin(),v.rend());
    std::printf("%s  (%zu members, %zu pieces)\n",label.c_str(),net.member_count(),v.size());
    double run=0;
    for(std::size_t i=0;i<v.size()&&i<6;++i){
      run+=v[i].first;
      std::printf("   piece %zu: %7d members %6.2f%%  (cumulative %6.2f%%)  y span %.1f..%.1f mm\n",
                  i+1,v[i].first,100.0*v[i].first/net.member_count(),
                  100.0*run/net.member_count(),ymin[v[i].second],ymax[v[i].second]);
    }
    int tiny=0,tinym=0;
    for(std::size_t i=0;i<v.size();++i) if(100.0*v[i].first/net.member_count()<1.0){++tiny;tinym+=v[i].first;}
    std::printf("   ...%d piece(s) under 1%% each, %d members total (%.2f%%)\n\n",
                tiny,tinym,100.0*tinym/net.member_count());
  }
  return 0;
}
