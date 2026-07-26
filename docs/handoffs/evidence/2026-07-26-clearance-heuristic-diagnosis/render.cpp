// render.cpp — a plain shaded + by-pseudo-face render of the shelf bracket, so
// the real hole count is visible rather than only asserted. Two views from
// opposite azimuths. PPM out (convert with sips).
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
using namespace topopt;

static void render(const TriangleMesh& mesh, const std::vector<int>& face,
                   bool byface, double az, const std::string& out, int W=1000,int H=800){
  Vec3 lo,hi; bounding_box(mesh,lo,hi);
  const Vec3 c{(lo.x+hi.x)/2,(lo.y+hi.y)/2,(lo.z+hi.z)/2};
  const double span=std::max({hi.x-lo.x,hi.y-lo.y,hi.z-lo.z});
  const double el=0.6, ca=std::cos(az),sa=std::sin(az),ce=std::cos(el),se=std::sin(el);
  const Vec3 fwd{-ce*ca,-ce*sa,-se}, right{-sa,ca,0}, up{-se*ca,-se*sa,ce};
  const double scale=0.40*std::min(W,H)/(span*0.5);
  std::vector<double> zb((size_t)W*H,1e30); std::vector<int> fb((size_t)W*H,-1); std::vector<double> sh((size_t)W*H,0);
  auto proj=[&](const Vec3&p,double&x,double&y,double&d){Vec3 e{p.x-c.x,p.y-c.y,p.z-c.z};x=W*.5+scale*(e.x*right.x+e.y*right.y+e.z*right.z);y=H*.5-scale*(e.x*up.x+e.y*up.y+e.z*up.z);d=e.x*fwd.x+e.y*fwd.y+e.z*fwd.z;};
  const Vec3 light{0.3,0.4,0.85};
  for(size_t t=0;t<mesh.triangles.size();++t){const auto&tr=mesh.triangles[t];const Vec3&p0=mesh.vertices[(size_t)tr[0]];const Vec3&p1=mesh.vertices[(size_t)tr[1]];const Vec3&p2=mesh.vertices[(size_t)tr[2]];
    Vec3 e1{p1.x-p0.x,p1.y-p0.y,p1.z-p0.z},e2{p2.x-p0.x,p2.y-p0.y,p2.z-p0.z};Vec3 n{e1.y*e2.z-e1.z*e2.y,e1.z*e2.x-e1.x*e2.z,e1.x*e2.y-e1.y*e2.x};double nl=std::sqrt(n.x*n.x+n.y*n.y+n.z*n.z);if(nl<=0)continue;n={n.x/nl,n.y/nl,n.z/nl};double lam=0.35+0.65*std::max(0.0,std::fabs(n.x*light.x+n.y*light.y+n.z*light.z));
    double x0,y0,d0,x1,y1,d1,x2,y2,d2;proj(p0,x0,y0,d0);proj(p1,x1,y1,d1);proj(p2,x2,y2,d2);
    int mnx=std::max(0,(int)std::floor(std::min({x0,x1,x2}))),mxx=std::min(W-1,(int)std::ceil(std::max({x0,x1,x2})));
    int mny=std::max(0,(int)std::floor(std::min({y0,y1,y2}))),mxy=std::min(H-1,(int)std::ceil(std::max({y0,y1,y2})));
    double area=(x1-x0)*(y2-y0)-(x2-x0)*(y1-y0);if(std::fabs(area)<1e-12)continue;
    for(int py=mny;py<=mxy;++py)for(int px=mnx;px<=mxx;++px){double fx=px+.5,fy=py+.5;double w0=((x1-fx)*(y2-fy)-(x2-fx)*(y1-fy))/area,w1=((x2-fx)*(y0-fy)-(x0-fx)*(y2-fy))/area,w2=1-w0-w1;if(w0<0||w1<0||w2<0)continue;double z=w0*d0+w1*d1+w2*d2;size_t idx=(size_t)py*W+px;if(z>=zb[idx])continue;zb[idx]=z;fb[idx]=face[t];sh[idx]=lam;}}
  auto col=[&](int f,double lam,unsigned char*rgb){double h=std::fmod(f*0.61803398875,1.0),s=0.6,v=0.95*lam;int i=(int)(h*6);double ff=h*6-i,p=v*(1-s),q=v*(1-s*ff),tt=v*(1-s*(1-ff)),r=0,g=0,b=0;switch(i%6){case 0:r=v;g=tt;b=p;break;case 1:r=q;g=v;b=p;break;case 2:r=p;g=v;b=tt;break;case 3:r=p;g=q;b=v;break;case 4:r=tt;g=p;b=v;break;case 5:r=v;g=p;b=q;break;}rgb[0]=(unsigned char)(255*std::min(1.0,r));rgb[1]=(unsigned char)(255*std::min(1.0,g));rgb[2]=(unsigned char)(255*std::min(1.0,b));};
  std::ofstream o(out,std::ios::binary);o<<"P6\n"<<W<<" "<<H<<"\n255\n";
  for(int py=0;py<H;++py)for(int px=0;px<W;++px){size_t idx=(size_t)py*W+px;unsigned char rgb[3]={24,26,30};if(fb[idx]>=0){if(byface){bool edge=false;for(int dy=-1;dy<=1&&!edge;++dy)for(int dx=-1;dx<=1&&!edge;++dx){int qx=px+dx,qy=py+dy;if(qx<0||qy<0||qx>=W||qy>=H)continue;if(fb[(size_t)qy*W+qx]!=fb[idx])edge=true;}if(edge){rgb[0]=rgb[1]=rgb[2]=10;}else col(fb[idx],sh[idx],rgb);}else{unsigned char g=(unsigned char)(210*sh[idx]);rgb[0]=g;rgb[1]=g;rgb[2]=(unsigned char)(230*sh[idx]);}}o.write((char*)rgb,3);}
}
int main(int argc,char**argv){const std::string root=argc>1?argv[1]:".";const std::string out=argc>2?argv[2]:".";
  PartModel pm=import_part(root+"/core/tests/fixtures/mesh/WallMount_ShelfBracket.stl");
  const auto& sm=pm.model;
  render(sm.mesh,sm.triangle_face,false,0.7,out+"/bracket_shaded_a.ppm");
  render(sm.mesh,sm.triangle_face,false,0.7+3.14159,out+"/bracket_shaded_b.ppm");
  render(sm.mesh,sm.triangle_face,true,0.7,out+"/bracket_faces_a.ppm");
  std::printf("rendered %d faces\n",sm.face_count);return 0;}
