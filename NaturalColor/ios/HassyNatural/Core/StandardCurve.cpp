#include "StandardCurve.h"
#include <algorithm>
#include <cmath>

extern "C" int hn_make_standard_curve(float *dest, size_t count,
                                      const double *base, size_t base_count, int lstar) {
    if (!dest || !base || count != 65536 || base_count != 1025) return -1;
    for (size_t i=0; i<base_count; ++i) if (!std::isfinite(base[i]) || base[i]<0 || base[i]>1) return -1;
    double x[6] = {0,.125,.25,.5,.75,1};
    double y[6] = {0,.0859375,.21875,.5,.76171875,1};
    for (int i=1;i<6;++i) {
        const double original = x[i];
        x[i] = original < .45852946567989455 ? original*.9170589313597891 : original*1.0829410686402108-.08294106864021078;
        y[i] = x[i]*y[i]/original;
    }
    double z[6] = {}, u[6] = {};
    for (int i=1;i<5;++i) {
        const double sig=(x[i]-x[i-1])/(x[i+1]-x[i-1]);
        const double p=sig*z[i-1]+2;
        z[i]=(sig-1)/p;
        const double delta=(y[i+1]-y[i])/(x[i+1]-x[i])-(y[i]-y[i-1])/(x[i]-x[i-1]);
        u[i]=(6*delta/(x[i+1]-x[i-1])-sig*u[i-1])/p;
    }
    for (int i=4;i>=0;--i) z[i]=z[i]*z[i+1]+u[i];
    for (size_t i=0;i<count;++i) {
        double v=double(i)/65536;
        v = v<=.25 ? v*1.2201699047004935 : (-.3914131639119884*v+1.4158764866564877)*v-.02446332274449925;
        v = v<=.25 ? v*1.4142135623730951 : (-.736379666441058*v+1.782403395593624)*v-.04602372915256603;
        if (v>1e-7) {
            const double position=v*1024;
            const size_t index=std::min(size_t(position),size_t(1023));
            const double f=position-double(index);
            const double lookup=base[index]*(1-f)+base[index+1]*f;
            const double gain=(.25*std::pow(lookup,1.8)+.75*v)/v;
            v*=gain;
        } else v=0;
        v=v<=.25 ? v*.8195579944626342 : (.32078578762198356*v+.6591651006516425)*v+.020049111726374025;
        v=std::pow(v,.4547069271758437);
        if (v>1e-7) {
            int j=0;while(j<4 && x[j+1]<=v) ++j;
            const double h=x[j+1]-x[j],a=(x[j+1]-v)/h,b=(v-x[j])/h;
            const double spline=a*y[j]+b*y[j+1]+((a*a*a-a)*z[j]+(b*b*b-b)*z[j+1])*h*h/6;
            const double gain=spline/v;
            v*=gain;
        } else v=0;
        if (lstar) {
            v=std::pow(v,2.19921875);
            v=v>.008856451679035631 ? 1.16*std::cbrt(v)-.16 : v*903.2962962962963/100;
        }
        dest[i]=float(std::trunc(std::max(0.,std::min(65535.,v*65536))))/65535.f;
    }
    return 0;
}
