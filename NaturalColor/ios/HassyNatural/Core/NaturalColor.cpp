#include "NaturalColor.h"
#include <algorithm>
#include <cmath>

namespace {
float bound(float v) { return std::clamp(v, 0.0f, 1.0f); }
float smooth(float lo, float hi, float v) {
    float t = bound((v-lo)/(hi-lo)); return t*t*(3-2*t);
}
}
extern "C" void hn_natural_pixel(const float in[3], float strength, float out[3]) {
    float original[3] = {bound(in[0]),bound(in[1]),bound(in[2])};
    float k=std::isfinite(strength) ? bound(strength) : 0;
    float r=original[0],g=original[1],b=original[2];
    float nr=1.010f*r+.003f*g-.006f*b;
    float ng=-.003f*r+1.006f*g-.001f*b;
    float nb=-.002f*r+.003f*g+.992f*b;
    r=nr;g=ng;b=nb;
    float y=.2126f*r+.7152f*g+.0722f*b;
    float base=y+(1-smooth(.012f,.18f,y))*.004f*(1-y);
    float sh=base>.64f ? .64f+(base-.64f)/(1+.42f*(base-.64f)) : base;
    float density=1-.018f*std::exp(-std::pow((base-.42f)/.28f,2));
    float sc=y>1e-5f ? bound(sh*density)/y : 1;
    r*=sc;g*=sc;b*=sc;
    y=.2126f*r+.7152f*g+.0722f*b;
    float cr=r-y,cg=g-y,cb=b-y;
    float ch=std::sqrt(cr*cr+cg*cg+cb*cb);
    float sat=(.988f-.060f*smooth(.62f,.98f,y))/(1+.18f*std::max(0.0f,ch-.16f));
    r=y+cr*sat;g=y+cg*sat;b=y+cb*sat;
    float green=bound((g-std::max(r,b))*3.2f);
    float yellow=green*bound((r-b+.03f)*2);
    g-=.005f*green+.004f*yellow;r-=.0015f*yellow;b+=.002f*green;
    float blue=bound((b-std::max(r,g))*2.5f);
    b-=.004f*blue;r+=.0015f*blue;
    float mid=std::exp(-std::pow((y-.43f)/.30f,2));
    r+=.0032f*mid;b-=.0018f*mid;
    float mn=std::min({r,g,b});
    if(mn<0){r-=mn;g-=mn;b-=mn;}
    float mx=std::max({r,g,b});
    if(mx>1){
        float yy=.2126f*r+.7152f*g+.0722f*b,den=mx-yy;
        if(den>1e-6f){float t=(1-yy)/den;r=yy+(r-yy)*t;g=yy+(g-yy)*t;b=yy+(b-yy)*t;}
    }
    out[0]=bound(original[0]+(r-original[0])*k);
    out[1]=bound(original[1]+(g-original[1])*k);
    out[2]=bound(original[2]+(b-original[2])*k);
}
extern "C" int hn_make_cube(float *rgba,size_t capacity,unsigned n,float strength){
    if(!rgba || n<2 || n>128 || capacity<size_t(n)*n*n*4) return 0;
    size_t i=0;
    for(unsigned b=0;b<n;b++)for(unsigned g=0;g<n;g++)for(unsigned r=0;r<n;r++){
        float in[3]={float(r)/(n-1),float(g)/(n-1),float(b)/(n-1)},out[3];
        hn_natural_pixel(in,strength,out);
        rgba[i++]=out[0];rgba[i++]=out[1];rgba[i++]=out[2];rgba[i++]=1;
    }
    return 1;
}
