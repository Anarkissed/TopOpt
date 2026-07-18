// gizmo_pick_oracle.cpp — headless ground-truth oracle for the liquid-glass orientation
// gizmo's SHARED-CONSTANTS picking (the orientation-gizmo-redesign task, handoff 105).
//
// This mirrors docs/design/gizmo_redesign.html (the authoritative design mock) byte-for-byte:
// the same CFG constants, the same SDF (sdEll / smin / cellDists / map), the same globalId
// classification, and the same perspective raymarch pick. It is the reference the Swift port
// (app/TopOptKit/Sources/TopOptFlows/OrientationGizmo.swift + …Metal.swift) must reproduce, and
// the exact (point → id) values baked into the Swift XCTests come from here.
//
// It is pure math (no Metal, no Swift), so it runs anywhere:
//     clang++ -O2 -std=c++17 Testing/gizmo_pick_oracle.cpp -o /tmp/gizmo_oracle && /tmp/gizmo_oracle
// Exit status is non-zero if any check fails.
//
// The Swift picker uses 32-bit Float; this file is templated so both `double` (the mock's JS
// precision) and `float` (the shader/Swift precision) can be checked — both must pass.

#include <cstdio>
#include <cmath>
#include <array>
#include <algorithm>
#include <string>

template <typename T> struct Oracle {
    using V3 = std::array<T, 3>;

    // ---- CFG, verbatim from the mock ----
    struct Cfg {
        T KCELL = T(0.09), KLOBE = T(0.095), CENTER_R = T(0.72);
        T FACE_C = T(0.80), FACE_N = T(0.38), FACE_T = T(0.92);
        T FSH_C = T(0.80), FSH_D = T(0.68), FSH_R1 = T(0.20), FSH_R2 = T(0.34);
        T EM_C = T(0.92), EM_R = T(0.18), EM_L = T(0.74);
        T EF_IN = T(0.86), EF_R = T(0.18), EF_L = T(0.62);
        T CN_C = T(0.885), CN_R = T(0.22);
        T CL_IN = T(0.70); T CL_R[3] = {T(0.13), T(0.14), T(0.16)};
        T GROOVE = T(0.045), GROOVE_W = T(0.085);
        T FOV = T(38), CAMZ = T(9.25);
    } C;

    static T smin(T a, T b, T k) {
        T h = std::min(std::max(T(0.5) + T(0.5) * (b - a) / k, T(0)), T(1));
        return b * (1 - h) + a * h - k * h * (1 - h);
    }
    static T sdEll(V3 p, V3 c, V3 r) {
        V3 q = {(p[0]-c[0])/r[0], (p[1]-c[1])/r[1], (p[2]-c[2])/r[2]};
        T k0 = std::sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]);
        T k1 = std::sqrt((q[0]/r[0])*(q[0]/r[0])+(q[1]/r[1])*(q[1]/r[1])+(q[2]/r[2])*(q[2]/r[2]));
        return k0*(k0-1)/std::max(k1, T(1e-4));
    }
    void cellDists(V3 p, T dc[8]) {
        V3 q = {std::fabs(p[0]), std::fabs(p[1]), std::fabs(p[2])};
        dc[0] = std::sqrt(p[0]*p[0]+p[1]*p[1]+p[2]*p[2]) - C.CENTER_R;
        T fx = sdEll(q, {C.FACE_C,0,0}, {C.FACE_N,C.FACE_T,C.FACE_T});
        fx = smin(fx, sdEll(q, {C.FSH_C,C.FSH_D,C.FSH_D}, {C.FSH_R1,C.FSH_R2,C.FSH_R2}), C.KLOBE);
        T fy = sdEll(q, {0,C.FACE_C,0}, {C.FACE_T,C.FACE_N,C.FACE_T});
        fy = smin(fy, sdEll(q, {C.FSH_D,C.FSH_C,C.FSH_D}, {C.FSH_R2,C.FSH_R1,C.FSH_R2}), C.KLOBE);
        T fz = sdEll(q, {0,0,C.FACE_C}, {C.FACE_T,C.FACE_T,C.FACE_N});
        fz = smin(fz, sdEll(q, {C.FSH_D,C.FSH_D,C.FSH_C}, {C.FSH_R2,C.FSH_R2,C.FSH_R1}), C.KLOBE);
        dc[1]=fx; dc[2]=fy; dc[3]=fz;
        T exy = sdEll(q, {C.EM_C,C.EM_C,0}, {C.EM_R,C.EM_R,C.EM_L});
        exy = smin(exy, sdEll(q, {C.EF_IN,1,0}, {C.EF_R,C.EF_R,C.EF_L}), C.KLOBE);
        exy = smin(exy, sdEll(q, {1,C.EF_IN,0}, {C.EF_R,C.EF_R,C.EF_L}), C.KLOBE);
        T eyz = sdEll(q, {0,C.EM_C,C.EM_C}, {C.EM_L,C.EM_R,C.EM_R});
        eyz = smin(eyz, sdEll(q, {0,C.EF_IN,1}, {C.EF_L,C.EF_R,C.EF_R}), C.KLOBE);
        eyz = smin(eyz, sdEll(q, {0,1,C.EF_IN}, {C.EF_L,C.EF_R,C.EF_R}), C.KLOBE);
        T ezx = sdEll(q, {C.EM_C,0,C.EM_C}, {C.EM_R,C.EM_L,C.EM_R});
        ezx = smin(ezx, sdEll(q, {C.EF_IN,0,1}, {C.EF_R,C.EF_L,C.EF_R}), C.KLOBE);
        ezx = smin(ezx, sdEll(q, {1,0,C.EF_IN}, {C.EF_R,C.EF_L,C.EF_R}), C.KLOBE);
        dc[4]=exy; dc[5]=eyz; dc[6]=ezx;
        T co = std::sqrt((q[0]-C.CN_C)*(q[0]-C.CN_C)+(q[1]-C.CN_C)*(q[1]-C.CN_C)+(q[2]-C.CN_C)*(q[2]-C.CN_C)) - C.CN_R;
        co = smin(co, sdEll(q, {C.CL_IN,1,1}, {C.CL_R[0]*T(1.5),C.CL_R[0],C.CL_R[0]}), C.KLOBE);
        co = smin(co, sdEll(q, {1,C.CL_IN,1}, {C.CL_R[1],C.CL_R[1]*T(1.5),C.CL_R[1]}), C.KLOBE);
        co = smin(co, sdEll(q, {1,1,C.CL_IN}, {C.CL_R[2],C.CL_R[2],C.CL_R[2]*T(1.5)}), C.KLOBE);
        dc[7]=co;
    }
    T mapF(V3 p) {
        T dc[8]; cellDists(p, dc);
        T d = dc[0], m1 = dc[0], m2 = T(1e9);
        for (int i = 1; i < 8; i++) {
            d = smin(d, dc[i], C.KCELL);
            if (dc[i] < m1) { m2 = m1; m1 = dc[i]; } else if (dc[i] < m2) { m2 = dc[i]; }
        }
        T s = std::min(std::max((m2-m1)/C.GROOVE_W, T(0)), T(1));
        return d + C.GROOVE * (1 - s*s*(3-2*s));
    }
    // Perspective pick (ro/rd already in MODEL space). Returns the {-1,0,1}^3 anchor + cell.
    bool pick(V3 ro, V3 rd, int &cell, V3 &anchor) {
        T t = C.CAMZ - 3;
        for (int i = 0; i < 72; i++) {
            V3 p = {ro[0]+rd[0]*t, ro[1]+rd[1]*t, ro[2]+rd[2]*t};
            T d = mapF(p);
            if (d < T(0.003)) {
                T dc[8]; cellDists(p, dc);
                T d1 = T(1e9); int i1 = 0;
                for (int j = 0; j < 8; j++) if (dc[j] < d1) { d1 = dc[j]; i1 = j; }
                cell = i1;
                auto s = [](T v){ return v > 0 ? T(1) : T(-1); };
                anchor = {0,0,0};
                if (i1==1) anchor[0]=s(p[0]);
                else if (i1==2) anchor[1]=s(p[1]);
                else if (i1==3) anchor[2]=s(p[2]);
                else if (i1==4) { anchor[0]=s(p[0]); anchor[1]=s(p[1]); }
                else if (i1==5) { anchor[1]=s(p[1]); anchor[2]=s(p[2]); }
                else if (i1==6) { anchor[0]=s(p[0]); anchor[2]=s(p[2]); }
                else if (i1==7) { anchor[0]=s(p[0]); anchor[1]=s(p[1]); anchor[2]=s(p[2]); }
                return true;   // cell 0 → Home, anchor stays (0,0,0)
            }
            t += d * T(0.7);
            if (t > C.CAMZ + 3) break;
        }
        return false;
    }
    static V3 norm(V3 v) { T l = std::sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]); return {v[0]/l, v[1]/l, v[2]/l}; }
    // world→view basis (rows x,y,z) for a camera looking from unit dir d, up +Y — like OrbitCamera.
    static void viewRot(V3 d, V3 &x, V3 &y, V3 &z) {
        z = norm(d); V3 up = {0,1,0};
        x = norm({up[1]*z[2]-up[2]*z[1], up[2]*z[0]-up[0]*z[2], up[0]*z[1]-up[1]*z[0]});
        y = {z[1]*x[2]-z[2]*x[1], z[2]*x[0]-z[0]*x[2], z[0]*x[1]-z[1]*x[0]};
    }
    static V3 RT(V3 x, V3 y, V3 z, V3 v) {  // R^T · v  (view → model)
        return {v[0]*x[0]+v[1]*y[0]+v[2]*z[0], v[0]*x[1]+v[1]*y[1]+v[2]*z[1], v[0]*x[2]+v[1]*y[2]+v[2]*z[2]};
    }
};

static const char* faceName(int axis, bool pos) {
    if (axis==0) return pos ? "Right" : "Left";
    if (axis==1) return pos ? "Top" : "Bottom";
    return pos ? "Front" : "Back";
}
static std::string regionId(int x, int y, int z) {
    std::string s; int order[3] = {1,2,0};
    for (int k = 0; k < 3; k++) { int axis = order[k]; int c = axis==0?x:(axis==1?y:z);
        if (c != 0) { if (!s.empty()) s += "-"; s += faceName(axis, c > 0); } }
    return s;
}

template <typename T>
int run(const char* label) {
    Oracle<T> O; using V3 = typename Oracle<T>::V3;
    int fail = 0, checks = 0;
    auto expect = [&](bool ok, const std::string& what) {
        checks++; if (!ok) { fail++; printf("  [%s] FAIL: %s\n", label, what.c_str()); }
    };

    // (1) All 26 canonical views: the centre ray must resolve to that region.
    for (int x=-1;x<=1;x++) for (int y=-1;y<=1;y++) for (int z=-1;z<=1;z++) {
        if (!x && !y && !z) continue;
        V3 dir = Oracle<T>::norm({(T)x,(T)y,(T)z});
        V3 ro = {dir[0]*O.C.CAMZ, dir[1]*O.C.CAMZ, dir[2]*O.C.CAMZ};
        V3 rd = {-dir[0], -dir[1], -dir[2]};
        int cell; V3 a; bool hit = O.pick(ro, rd, cell, a);
        std::string want = regionId(x,y,z);
        std::string got = hit ? regionId((int)a[0],(int)a[1],(int)a[2]) : "MISS";
        expect(hit && got == want, "canonical " + want + " got " + got);
    }
    // (2) Clamped poles (elevation 85°, as OrbitCamera clamps them) still resolve.
    T maxE = T(M_PI/2 - 0.05), cE = std::cos(maxE), sE = std::sin(maxE), A = T(M_PI/4);
    auto poleCheck = [&](const char* want, V3 d) {
        d = Oracle<T>::norm(d);
        V3 ro = {d[0]*O.C.CAMZ, d[1]*O.C.CAMZ, d[2]*O.C.CAMZ}, rd = {-d[0],-d[1],-d[2]};
        int cell; V3 a; bool hit = O.pick(ro, rd, cell, a);
        expect(hit && regionId((int)a[0],(int)a[1],(int)a[2]) == want, std::string("pole ") + want);
    };
    poleCheck("Top",    {cE*std::sin(A), sE, cE*std::cos(A)});
    poleCheck("Bottom", {cE*std::sin(A), -sE, cE*std::cos(A)});

    // (3) Front-view synthetic rays at size 200 — the exact points baked into the XCTests.
    T tf = std::tan(O.C.FOV * T(0.5) * T(M_PI) / T(180));
    V3 fx, fy, fz; Oracle<T>::viewRot({0,0,1}, fx, fy, fz);
    auto hitPt = [&](T px, T py, T w, T h) -> std::string {
        T ux = (px/w)*2-1, uy = 1-(py/h)*2;
        V3 roW = {0,0,O.C.CAMZ}, rdW = Oracle<T>::norm({ux*tf, uy*tf, T(-1)});
        V3 ro = Oracle<T>::RT(fx,fy,fz,roW), rd = Oracle<T>::norm(Oracle<T>::RT(fx,fy,fz,rdW));
        int cell; V3 a; bool hit = O.pick(ro, rd, cell, a);
        return hit ? (cell==0 ? "HOME" : regionId((int)a[0],(int)a[1],(int)a[2])) : "MISS";
    };
    expect(hitPt(100,100,200,200) == "Front",           "front centre");
    expect(hitPt(100, 70,200,200) == "Top-Front",       "front upper band edge");
    expect(hitPt(130, 70,200,200) == "Top-Front-Right",  "front upper-right corner");
    expect(hitPt(100, 10,200,200) == "MISS",            "front far-top margin miss");
    expect(hitPt(  2,  2, 74, 74) == "MISS",            "corner outside silhouette");

    printf("[%s] %d checks, %d failed\n", label, checks, fail);
    return fail;
}

int main() {
    int fail = 0;
    fail += run<double>("double");
    fail += run<float>("float");
    printf("%s\n", fail == 0 ? "OK — all picking checks pass" : "FAILED");
    return fail == 0 ? 0 : 1;
}
