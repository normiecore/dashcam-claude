#include "RecoveredColor.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>
// Provenance: HNCSMatrix.provenance.json. C and A recovered statically from
// PhocusAndroid1.1.0 ELF SHA d757237554529f8ab485f88f2c5e5399fbc8d56035c79b8e057b41a40fd055e4.
// Bradford/sRGB bridge is an explicit phone integration choice, not a recovered
// iPhone sensor calibration. Arithmetic below translates fragment0x3136dff.
namespace {
constexpr float input[3][3] = {
 {0.22065768270191272f,0.6547762036689073f,0.12456597392549729f},
 {-0.1178468681274096f,-0.3297894099981833f,0.44773627811162264f},
 {0.3121446064237095f,-0.2499638530923849f,-0.062080753345294754f}};
constexpr float nativeOut[3][2] = {
 {-0.00012188356583590878f,1.4022426952670104f},
 {-0.34562707769717743f,-0.7144779490935292f},
 {1.7710155002182766f,-0.0001535080964643524f}};
constexpr float post[3][3] = {
 {1.5487231627750677f,-0.4931464183849373f,-0.055576604686429f},
 {-0.06253000270524556f,1.0766231784366227f,-0.01409303602767471f},
 {-0.015208859998233059f,-0.07651119599334996f,1.0917201956952851f}};
float dot(const float row[3],const float p[3]) {
 return row[0]*p[0]+row[1]*p[1]+row[2]*p[2];
}
}
static int recovered_pixel(const float rgb[3],const float* cbcr,
 size_t width,size_t height,float cbStart,float crStart,float div,float nativeScale,const float* film,size_t filmCount,float out[3]) {
 if (!rgb || !out || !cbcr || (film && filmCount!=65536) || width<2 || height<2 ||
     width>std::numeric_limits<size_t>::max()/height/2 ||
     !std::isfinite(cbStart) || !std::isfinite(crStart) ||
     !std::isfinite(div) || div<=0 || !std::isfinite(nativeScale) || nativeScale<=0) return 0;
 float p[3];
 for (int i=0;i<3;++i) {
  if (!std::isfinite(rgb[i])) return 0;
  p[i]=std::clamp(rgb[i],0.0f,1.0f)*65535.0f;
 }
 const float avg=(p[0]+p[1]+p[2])*0.3333333f;
 if (avg==0) {out[0]=out[1]=out[2]=0;return 1;}
 float dmax=std::max({std::fabs(p[0]-avg),std::fabs(p[1]-avg),std::fabs(p[2]-avg)});
 float gray=std::clamp((dmax/avg-0.005f)/(0.07f-0.005f),0.0f,1.0f);
 float ycc[3];for (int i=0;i<3;++i) ycc[i]=dot(input[i],p);
 const float L=15500.0f/nativeScale;
 if (!std::isfinite(L) || L<=0) return 0;
 const float k=-0.123f;
 const float limit=ycc[0]<L ? (k/(L*L)*ycc[0]*ycc[0] + (-2*k/L)*ycc[0] + (1+k)) : 1.0f;
 gray=std::max(std::min(gray,limit),0.0f);
 const float Y=std::max(ycc[0],1e-10f);
 const float x=std::clamp(ycc[1]*div/Y-cbStart,0.0f,float(width-1));
 const float y=std::clamp(ycc[2]*div/Y-crStart,0.0f,float(height-1));
 // Source quirk: fract occurs BEFORE integer index clamp. In particular, the
 // exact final grid index picks penultimate cell with zero fraction.
 const float fx=std::floor(x),fy=std::floor(y),dx=x-fx,dy=y-fy;
 const size_t ix=std::min(size_t(fx),width-2),iy=std::min(size_t(fy),height-2);
 float chroma[2];
 for (size_t c=0;c<2;++c) {
  const float a=cbcr[(iy*width+ix)*2+c],b=cbcr[(iy*width+ix+1)*2+c];
  const float c0=cbcr[((iy+1)*width+ix)*2+c],d=cbcr[((iy+1)*width+ix+1)*2+c];
  if (!std::isfinite(a)||!std::isfinite(b)||!std::isfinite(c0)||!std::isfinite(d)) return 0;
  chroma[c]=((a*(1-dx)+b*dx)*(1-dy)+(c0*(1-dx)+d*dx)*dy)*Y*gray;
 }
 float native[3],result[3];
 for (int i=0;i<3;++i) native[i]=(Y+chroma[0]*(nativeOut[i][0]/div)+chroma[1]*(nativeOut[i][1]/div))/65535.0f;
 if (film) {
  if (filmCount!=65536) return 0;
  for (int i=0;i<3;++i) {
   const float index=std::min(std::max(native[i],0.0f)*65536.0f,65535.0f);
   const size_t lo=size_t(index); // Native film shader uses floor, not interpolation.
   if (!std::isfinite(film[lo])) return 0;
   const float encoded=film[lo];
   // SDR Standard already includes gamma. Explicit application integration:
   // undo native gamma here, then transform linear nativeRGB back to sRGB.
   native[i]=std::pow(std::max(encoded,0.0f),2.19921875f);
  }
 }
 for (int i=0;i<3;++i) {result[i]=dot(post[i],native);if(!std::isfinite(result[i]))return 0;}
 for (int i=0;i<3;++i) out[i]=result[i];
 return 1;
}

extern "C" int hn_recovered_pixel(const float rgb[3],const float* cbcr,
 size_t width,size_t height,float cbStart,float crStart,float div,float nativeScale,float out[3]) {
 return recovered_pixel(rgb,cbcr,width,height,cbStart,crStart,div,nativeScale,nullptr,0,out);
}
extern "C" int hn_recovered_pixel_with_curve(const float rgb[3],const float* cbcr,
 size_t width,size_t height,float cbStart,float crStart,float div,float nativeScale,
 const float* film,size_t filmCount,float out[3]) {
 if (!film) return 0;
 return recovered_pixel(rgb,cbcr,width,height,cbStart,crStart,div,nativeScale,film,filmCount,out);
}
// Scene tone stage. Keep arithmetic synchronized with RecoveredKernel.ci.metal.
namespace {
constexpr float filmStops=3.0f;          // log2(1/HN_FILM_MIDDLE_GREY)
constexpr float kneeStops=1.0f;          // grey and +1 EV keep the Standard curve exactly
constexpr float fillFloor=-7.0f;         // stops below middle grey where fill reaches zero
constexpr float fillShape=1.5688f;       // places the fill peak 2.5 stops below grey
constexpr float maxHDRStops=3.0f;        // HNCS HDR documents up to +3 stops
// Stops removed at t (stops above film grey). A rational log-domain shoulder
// from the knee: slope 1 at the knee and the measured white (3+compression)
// lands on film white (3); beyond it values keep rising and clip in the film.
float compression_ev(float t,float compression) {
 if (!(compression>0) || !(t>kneeStops)) return 0;
 const float span=filmStops-kneeStops,range=span+compression,ratio=range/span;
 const float u=(t-kneeStops)/range;
 return t-(kneeStops+span*ratio*u/(1+(ratio-1)*u));
}
float smooth01(float x) {const float c=std::clamp(x,0.0f,1.0f);return c*c*(3-2*c);}
float scene_tone_ev(float n,const hn_scene_tone& tone) {
 if (!(n>0)) return 0;
 const float t=std::log2(n/HN_FILM_MIDDLE_GREY);
 float ev=-compression_ev(t,tone.compression);
 if (tone.shadowFill>0 && t<0 && t>fillFloor) {
  const float u=std::pow((t-fillFloor)/-fillFloor,fillShape);
  const float s=std::sin(3.14159265358979f*u);
  ev+=tone.shadowFill*s*s;
 }
 return ev;
}
bool valid_tone(const hn_scene_tone* tone) {
 return tone && std::isfinite(tone->exposure) && tone->exposure>0 &&
  std::isfinite(tone->compression) && tone->compression>=0 && tone->compression<=HN_MAX_COMPRESSION &&
  std::isfinite(tone->shadowFill) && tone->shadowFill>=0 && tone->shadowFill<=HN_MAX_SHADOW_FILL;
}
}

extern "C" int hn_apply_scene_tone(const float rgb[3],const hn_scene_tone* tone,float out[3]) {
 if (!rgb || !out || !valid_tone(tone)) return 0;
 float x[3];
 for (int i=0;i<3;++i) {if (!std::isfinite(rgb[i])) return 0; x[i]=rgb[i]*tone->exposure;}
 // A max(R,G,B) gain keeps hue and keeps compressed highlights within [0,1].
 const float gain=std::exp2(scene_tone_ev(std::max({x[0],x[1],x[2]}),*tone));
 for (int i=0;i<3;++i) x[i]*=gain;
 // Folded highlights approach white neutrally instead of clipping per channel
 // into pink or cyan casts. Scenes without compression are unchanged.
 if (tone->compression>0) {
  const float peak=std::max({x[0],x[1],x[2]}),w=smooth01((peak-0.9f)/0.1f);
  for (int i=0;i<3;++i) x[i]+=(peak-x[i])*w;
 }
 for (int i=0;i<3;++i) out[i]=x[i];
 return 1;
}

extern "C" int hn_scene_highlight_ev(const float rgb[3],const hn_scene_tone* tone,float* ev) {
 if (!rgb || !ev || !valid_tone(tone)) return 0;
 for (int i=0;i<3;++i) if (!std::isfinite(rgb[i])) return 0;
 const float n=std::max({rgb[0],rgb[1],rgb[2]})*tone->exposure;
 *ev=n>0 ? std::min(compression_ev(std::log2(n/HN_FILM_MIDDLE_GREY),tone->compression),maxHDRStops) : 0.0f;
 return 1;
}

extern "C" int hn_measure_scene(const float* rgba,size_t count,hn_scene_stats* out) {
 if (!rgba || !out || count==0) return 0;
 std::vector<float> peaks;peaks.reserve(count);
 size_t dark=0;
 const float darkLimit=HN_SCENE_MIDDLE_GREY*std::exp2(-2.5f);
 for (size_t i=0;i<count;++i) {
  const float r=rgba[i*4],g=rgba[i*4+1],b=rgba[i*4+2];
  if (!std::isfinite(r) || !std::isfinite(g) || !std::isfinite(b)) continue;
  peaks.push_back(std::max({r,g,b,0.0f}));
  if (0.2126f*r+0.7152f*g+0.0722f*b<darkLimit) ++dark;
 }
 if (peaks.empty()) return 0;
 const size_t index=std::min(peaks.size()-1,size_t(double(peaks.size()-1)*0.995));
 std::nth_element(peaks.begin(),peaks.begin()+index,peaks.end());
 out->white=peaks[index];
 out->darkFraction=float(double(dark)/double(peaks.size()));
 return 1;
}

extern "C" int hn_choose_scene_tone(const hn_scene_stats* stats,float exposureEV,hn_scene_tone* out) {
 if (!stats || !out || !std::isfinite(stats->white) || stats->white<0 || !std::isfinite(exposureEV) ||
     !std::isfinite(stats->darkFraction) || stats->darkFraction<0 || stats->darkFraction>1) return 0;
 const float exposure=HN_RAW_FILM_EXPOSURE;
 const float white=stats->white*std::exp2(exposureEV)*exposure;
 const float compression=white>1 ? std::min(std::log2(white),HN_MAX_COMPRESSION) : 0.0f;
 const float f=std::clamp((stats->darkFraction-0.15f)/(0.45f-0.15f),0.0f,1.0f);
 *out={exposure,compression,HN_MAX_SHADOW_FILL*f*f*(3-2*f)};
 return 1;
}

extern "C" int hn_toned_pixel_with_curve(const float rgb[3],const hn_scene_tone* tone,const float* cbcr,
 size_t width,size_t height,float cbStart,float crStart,float div,float nativeScale,
 const float* film,size_t filmCount,float out[3]) {
 float toned[3];
 if (!film || !hn_apply_scene_tone(rgb,tone,toned)) return 0;
 return recovered_pixel(toned,cbcr,width,height,cbStart,crStart,div,nativeScale,film,filmCount,out);
}

extern "C" int hn_make_reference_cube_shaped(float* rgba,size_t capacity,unsigned n,float strength,
 const float* table,size_t width,size_t height,float cbStart,float crStart,float div,
 float nativeScale,const float* film,size_t filmCount,float inputPower) {
 if (!std::isfinite(inputPower) || inputPower<=0) return 0;
 if (!rgba || n<2 || n>256 || !std::isfinite(strength)) return 0;
 const size_t required=size_t(n)*n*n*4;
 if (capacity<required || !film || filmCount!=65536) return 0;
 strength=std::clamp(strength,0.0f,1.0f);
 size_t index=0;
 for (unsigned b=0;b<n;++b) for (unsigned g=0;g<n;++g) for (unsigned r=0;r<n;++r) {
  float rgb[3]={std::pow(float(r)/float(n-1),inputPower),std::pow(float(g)/float(n-1),inputPower),std::pow(float(b)/float(n-1),inputPower)},mapped[3];
  if (!recovered_pixel(rgb,table,width,height,cbStart,crStart,div,nativeScale,film,filmCount,mapped)) return 0;
  for (int c=0;c<3;++c) rgba[index++]=std::clamp(rgb[c]+(mapped[c]-rgb[c])*strength,0.0f,1.0f);
  rgba[index++]=1.0f;
 }
 return 1;
}

extern "C" int hn_make_reference_cube(float* rgba,size_t capacity,unsigned n,float strength,
 const float* table,size_t width,size_t height,float cbStart,float crStart,float div,
 float nativeScale,const float* film,size_t filmCount) {
 return hn_make_reference_cube_shaped(rgba,capacity,n,strength,table,width,height,cbStart,crStart,div,nativeScale,film,filmCount,1.0f);
}
