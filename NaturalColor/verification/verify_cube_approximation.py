#!/usr/bin/env python3
"""Quantify uniform/shaped RGB-cube interpolation against direct recovered core."""
import ctypes,json,subprocess,tempfile
from pathlib import Path
import numpy as np
from scipy.ndimage import map_coordinates
APP=Path(__file__).resolve().parents[1];res=APP/'ios/HassyNatural/Resources'
info=json.loads((res/'ReferenceProfile.json').read_text());table=np.fromfile(res/info['resource'],dtype='<f4');film=np.fromfile(res/'StandardCurve.f32',dtype='<f4')
rng=np.random.default_rng(1729)
groups={'uniform_linear':rng.uniform(0,1,(8192,3)).astype(np.float32),'shadows':rng.uniform(0,.02,(4096,3)).astype(np.float32),'neutral_ramp':np.repeat(np.linspace(0,1,4097)[:,None],3,axis=1).astype(np.float32)}
samples=np.concatenate(list(groups.values()));F=ctypes.c_float;P=ctypes.POINTER(F)
def encoded(x):return np.where(x<=.0031308,x*12.92,1.055*np.maximum(x,0)**(1/2.4)-.055)
with tempfile.TemporaryDirectory() as td:
 so=Path(td)/'core.so';subprocess.run(['c++','-std=c++17','-O2','-ffp-contract=off','-shared','-fPIC',str(APP/'ios/HassyNatural/Core/RecoveredColor.cpp'),'-o',str(so)],check=True)
 lib=ctypes.CDLL(str(so));fn=lib.hn_recovered_pixel_with_curve
 fn.argtypes=[P,P,ctypes.c_size_t,ctypes.c_size_t,F,F,F,F,P,ctypes.c_size_t,P];fn.restype=ctypes.c_int
 cube_fn=lib.hn_make_reference_cube_shaped;cube_fn.argtypes=[P,ctypes.c_size_t,ctypes.c_uint,F,P,ctypes.c_size_t,ctypes.c_size_t,F,F,F,F,P,ctypes.c_size_t,F];cube_fn.restype=ctypes.c_int
 common=[table.ctypes.data_as(P),info['width'],info['height'],*info['start'],info['divisor'],1.,film.ctypes.data_as(P),len(film)]
 direct=np.empty_like(samples)
 for i,pixel in enumerate(samples):assert fn(pixel.ctypes.data_as(P),*common,direct[i].ctypes.data_as(P))==1
 direct=np.clip(direct,0,1)
 reports=[]
 for n,power in [(65,1.),(65,2.),(128,2.)]:
  cube=np.empty((n,n,n,4),dtype=np.float32)
  assert cube_fn(cube.ctypes.data_as(P),cube.size,n,1.,*common,power)==1
  coords=(samples**(1/power)*(n-1)).T[[2,1,0]]
  interpolated=np.stack([map_coordinates(cube[...,c],coords,order=1,mode='nearest',prefilter=False) for c in range(3)],axis=1)
  error=np.max(np.abs(interpolated-direct),axis=1);encoded_error=np.max(np.abs(encoded(interpolated)-encoded(direct)),axis=1)*255
  cursor=0;pergroup={}
  for name,g in groups.items():
   e=error[cursor:cursor+len(g)];e8=encoded_error[cursor:cursor+len(g)];cursor+=len(g)
   pergroup[name]={'pixels':len(g),'p50_max_channel_linear_error':float(np.median(e)),'p95_max_channel_linear_error':float(np.quantile(e,.95)),'max_channel_linear_error':float(e.max()),'p95_max_channel_srgb_8bit_error':float(np.quantile(e8,.95)),'max_channel_srgb_8bit_error':float(e8.max())}
  reports.append({'dimension':n,'input_power':power,'groups':pergroup})
 result={'method':'Own C++ exact native2DLUT+floor Standard vs scipy trilinear interpolation of same C++ generated CoreImage cubes; clampdirectRGBtoexport[0,1] beforecomparison','seed':1729,'results':reports,'limitations':['3Dcube is approximation; native2DLUT fract-before-index-clamp creates boundary discontinuities','CoreImage GPU precision/color management can introduce additional differences; verifyondevice','Input shaping and output inversegamma bridge are explicit application integration','No comparison threshold establishes Phocus rendering equivalence']}
 print(json.dumps(result,indent=2));(APP/'verification/cube-approximation-results.json').write_text(json.dumps(result,indent=2)+'\n')
