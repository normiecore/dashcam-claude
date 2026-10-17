#!/usr/bin/env python3
"""Compare portable compiled C++ to independent recovered shader translation.
Requires numpy and the research lab's shader_reference.py; does not run target
binaries or require GPU/Node. The C++ compiled here is our own portable source.
"""
import argparse,ctypes,json,subprocess,sys,tempfile
from pathlib import Path
import numpy as np

APP=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--lab',type=Path,default=Path('/workspace/hncs-lab'));a=p.parse_args()
sys.path.insert(0,str(a.lab));from shader_reference import render,native_desaturation,lookup
resources=APP/'ios/HassyNatural/Resources'
contract=json.loads((resources/'HNCSMatrix.provenance.json').read_text())['phone_adapter']
im=np.pad(np.array(contract['input_matrix_rows'],dtype=np.float32),((0,0),(0,1)))
om=np.pad(np.array(contract['shader_native_output_rows'],dtype=np.float32),((0,0),(0,1)))
post=np.array(contract['post_shader_native_rgb_to_linear_srgb_rows'],dtype=np.float32)
rng=np.random.default_rng(49152)
# Seeded arbitrary colors, clipping cases, neutrals, nearblack and exactblack.
samples=np.concatenate([rng.uniform(-.2,1.2,(2048,3)),np.repeat(np.linspace(0,1,65)[:,None],3,axis=1),np.array([[0,0,0],[1e-12,0,0],[1,0,0],[0,1,0],[0,0,1]])]).astype(np.float32)
F=ctypes.c_float;P=ctypes.POINTER(F)
with tempfile.TemporaryDirectory() as td:
 libpath=Path(td)/'recovered.so'
 subprocess.run(['c++','-std=c++17','-O2','-ffp-contract=off','-shared','-fPIC',str(APP/'ios/HassyNatural/Core/RecoveredColor.cpp'),'-o',str(libpath)],check=True)
 lib=ctypes.CDLL(str(libpath)); fn=lib.hn_recovered_pixel
 fn.argtypes=[P,P,ctypes.c_size_t,ctypes.c_size_t,F,F,F,F,P];fn.restype=ctypes.c_int
 runs=[]
 tables=[('synthetic',rng.uniform(-30,30,(5,5,2)).astype(np.float32),[-2.,-2.],32.)]
 metadata=resources/'ReferenceProfile.json'
 if metadata.exists():
  info=json.loads(metadata.read_text());table=np.fromfile(resources/info['resource'],dtype='<f4').reshape(info['height'],info['width'],2)
  tables.append(('reference',table,info['start'],float(info['divisor'])))
 for name,table,start,div in tables:
  output=np.zeros_like(samples)
  for i,pixel in enumerate(samples):
   ok=fn(pixel.ctypes.data_as(P),table.ctypes.data_as(P),table.shape[1],table.shape[0],*start,div,1.,output[i].ctypes.data_as(P));assert ok==1
  out_matrix=om.copy();out_matrix[:,1:3]/=np.float32(div)
  rgba=np.concatenate([samples,np.ones((len(samples),1),dtype=np.float32)],axis=1)
  kwargs=native_desaturation(1.)
  with np.errstate(invalid='ignore',divide='ignore'):
   expected=render(rgba,input_matrix=im,output_matrix=out_matrix,input_ev=1.,hr_trunc=1.,hr_max=1.,div_factor=div,start_cbcr=np.array(start),cbcr_limits=np.array(table.shape[1::-1])-1,table=table,**kwargs)[:,:3]@post.T
  black=np.all(np.clip(samples,0,1)==0,axis=1);expected[black]=0
  assert np.isfinite(output).all()
  err=float(np.max(np.abs(output-expected)))
  # Float32 native matrices, cancellation and table interpolation versus float64
  # translation: absolute linear-RGB tolerance, not perceptual image equivalence.
  assert err<3e-5,(name,err)
  runs.append({'table':name,'pixels':len(samples),'max_absolute_linear_rgb_error':err,'tolerance':3e-5})
 # Verify native-domain film before postmatrix using independently computed
 # Python fragment output, then explicit encoded->linear gamma integration.
 curve_fn=lib.hn_recovered_pixel_with_curve
 curve_fn.argtypes=fn.argtypes[:-1]+[P,ctypes.c_size_t,P];curve_fn.restype=ctypes.c_int
 film=np.fromfile(resources/'StandardCurve.f32',dtype='<f4')
 info=json.loads(metadata.read_text());table=np.fromfile(resources/info['resource'],dtype='<f4').reshape(info['height'],info['width'],2)
 start=info['start'];div=float(info['divisor']);out_matrix=om.copy();out_matrix[:,1:3]/=div
 rgba=np.concatenate([samples,np.ones((len(samples),1),dtype=np.float32)],axis=1)
 with np.errstate(invalid='ignore',divide='ignore'):
  native=render(rgba,input_matrix=im,output_matrix=out_matrix,input_ev=1.,hr_trunc=1.,hr_max=1.,div_factor=div,start_cbcr=np.array(start),cbcr_limits=np.array(table.shape[1::-1])-1,table=table,**native_desaturation(1.))[:,:3]
 black=np.all(np.clip(samples,0,1)==0,axis=1);native[black]=0
 positions=np.clip(native*65536,0,65535)
 encoded=film[np.floor(positions).astype(np.int64)]
 expected=np.maximum(encoded,0)**2.19921875@post.T;expected[black]=0
 curve_output=np.zeros_like(samples)
 for i,pixel in enumerate(samples):
  assert curve_fn(pixel.ctypes.data_as(P),table.ctypes.data_as(P),table.shape[1],table.shape[0],*start,div,1.,film.ctypes.data_as(P),len(film),curve_output[i].ctypes.data_as(P))==1
 curve_error=float(np.max(np.abs(curve_output-expected)));assert curve_error<1e-4,curve_error
 runs.append({'table':'reference_with_native_domain_standard_film','pixels':len(samples),'max_absolute_linear_rgb_error':curve_error,'tolerance':1e-4,'precision_note':'Floor lookup can differ by one16-bit entry when float32 and float64 inputs straddle an integer boundary'})
 cube_fn=lib.hn_make_reference_cube
 cube_fn.argtypes=[P,ctypes.c_size_t,ctypes.c_uint,F,P,ctypes.c_size_t,ctypes.c_size_t,F,F,F,F,P,ctypes.c_size_t];cube_fn.restype=ctypes.c_int
 n=17;cube=np.empty((n,n,n,4),dtype=np.float32)
 assert cube_fn(cube.ctypes.data_as(P),cube.size,n,0.,table.ctypes.data_as(P),table.shape[1],table.shape[0],*start,div,1.,film.ctypes.data_as(P),len(film))==1
 assert np.all(cube[...,3]==1)
 for b,g,r in [(0,0,0),(16,16,16),(3,7,11)]:assert np.allclose(cube[b,g,r,:3],[r/16,g/16,b/16],atol=1e-7)
 assert cube_fn(cube.ctypes.data_as(P),cube.size-1,n,0.,table.ctypes.data_as(P),table.shape[1],table.shape[0],*start,div,1.,film.ctypes.data_as(P),len(film))==0
 # Independent boundary controls ensure upper-bound fracture behavior preserved.
 t=np.arange(5*5*2,dtype=np.float64).reshape(5,5,2)
 assert np.array_equal(lookup(t,np.array([0.,0.])),t[0,0])
 assert np.array_equal(lookup(t,np.array([4.,4.])),t[3,3])
 valid=np.ones(3,dtype=np.float32);out=np.zeros(3,dtype=np.float32)
 table=t.astype(np.float32)
 assert fn(valid.ctypes.data_as(P),table.ctypes.data_as(P),1,5,-2,-2,32,1,out.ctypes.data_as(P))==0
 assert fn(valid.ctypes.data_as(P),table.ctypes.data_as(P),5,5,-2,-2,32,0,out.ctypes.data_as(P))==0
 report={'status':'pass','method':'Own C++ versus recovered Python fragment translation plus explicit phone matrix bridge','runs':runs,'boundary_controls':'lower and exact upper grid; invalid dimensions/scale; exactblack zero','black_policy':'Original gray computation undefined at exactblack; application explicitly returnszero','limitations':'Arithmetic parity does not establish Phocus output or iPhone sensor calibration equivalence'}
 print(json.dumps(report,indent=2))
