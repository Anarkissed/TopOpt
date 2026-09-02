// One table, one statistic set, uniform AND graded: top-1, top-2, top-5, dust,
// bridges. The earlier report quoted top-5 for uniform and top-2 for graded, which
// made two rows with the same measurements look like different verdicts.
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
  std::printf("%-9s %9s %10s %8s %8s %8s %9s\n","config","segments","length_mm","top-2","top-5","dust","bridges");
  for(int a=1;a<argc;a+=2){
    const std::string label=argv[a],path=argv[a+1];
    std::vector<topopt::BeamSegment> segs;
    { std::ifstream f(path); std::string ln;
      while(std::getline(f,ln)){ std::istringstream is(ln); std::string t; is>>t;
        if(t!="SEG")continue; topopt::BeamSegment s; double r;
        is>>s.a.x>>s.a.y>>s.a.z>>s.b.x>>s.b.y>>s.b.z>>r; s.radius_mm=r; segs.push_back(s);} }
    if(segs.empty()){std::printf("%-9s (none)\n",label.c_str());continue;}
    const topopt::BeamNetwork net=topopt::build_beam_network(segs);
    std::vector<int> par(net.node_count());
    for(std::size_t i=0;i<par.size();++i)par[i]=int(i);
    std::function<int(int)> fnd=[&](int x){while(par[x]!=x){par[x]=par[par[x]];x=par[x];}return x;};
    for(const auto&m:net.members){const int x=fnd(m.node_a),y=fnd(m.node_b);if(x!=y)par[x>y?x:y]=x<y?x:y;}
    std::map<int,int> cnt; for(const auto&m:net.members)++cnt[fnd(m.node_a)];
    std::vector<int> cs; for(auto&kv:cnt)cs.push_back(kv.second);
    std::sort(cs.rbegin(),cs.rend());
    const double tot=double(net.member_count());
    double t1=cs[0], t2=t1+(cs.size()>1?cs[1]:0), t5=0;
    for(std::size_t i=0;i<cs.size()&&i<5;++i)t5+=cs[i];
    const std::vector<char> br=topopt::beam_network_bridges(net);
    std::size_t nb=0; for(char c:br)nb+=c?1u:0u;
    double L=0;
    for(const auto&m:net.members){const auto&p1=net.nodes[m.node_a];const auto&q1=net.nodes[m.node_b];
      L+=std::sqrt((p1.x-q1.x)*(p1.x-q1.x)+(p1.y-q1.y)*(p1.y-q1.y)+(p1.z-q1.z)*(p1.z-q1.z));}
    (void)t1;
    std::printf("%-9s %9zu %10.0f %7.2f%% %7.2f%% %7.2f%% %8.1f%%\n",label.c_str(),
                net.member_count(),L,100*t2/tot,100*t5/tot,100*(tot-t2)/tot,
                100.0*double(nb)/double(br.size()));
  }
  return 0;
}
