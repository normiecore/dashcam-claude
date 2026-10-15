#!/usr/bin/env python3
"""Compare fixed recovered application operator to public official companions.
No image fitting, no parameter search, no network. Uses prior registered small
arrays; decode their encoded sRGB baseline before native processing.
"""
import argparse,ctypes,hashlib,json,subprocess,sys,tempfile
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
APP=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--lab',type=Path,default=Path('/workspace/hncs-lab'));args=p.parse_args();lab=args.lab
sys.path[:0]=[str(lab/'scripts'),str(lab)]
from compare_official_samples import metrics,srgb_encode
res=APP/'ios/HassyNatural/Resources';info=json.loads((res/'ReferenceProfile.json').read_text())
table=np.fromfile(res/info['resource'],dtype='<f4');film=np.fromfile(res/'StandardCurve.f32',dtype='<f4')
original={x['pair_id']:x for x in json.loads((lab/'evidence/official-public-comparisons.json').read_text())}
folder=APP/'verification/public-comparisons';folder.mkdir(parents=True,exist_ok=True)
F=ctypes.c_float;P=ctypes.POINTER(F)
reports=[]
with tempfile.TemporaryDirectory() as td:
 shared=Path(td)/'reference.so'
 subprocess.run(['c++','-std=c++17','-O2','-ffp-contract=off','-shared','-fPIC',str(APP/'ios/HassyNatural/Core/RecoveredColor.cpp'),'-o',str(shared)],check=True)
 native=ctypes.CDLL(str(shared));fn=native.hn_recovered_pixel_with_curve
 fn.argtypes=[P,P,ctypes.c_size_t,ctypes.c_size_t,F,F,F,F,P,ctypes.c_size_t,P];fn.restype=ctypes.c_int
 for file in sorted((lab/'artifacts/public-comparisons').glob('*-aligned.npz')):
  pair=file.name.removesuffix('-aligned.npz');arrays=np.load(file);target=arrays['published'];baseline=arrays['libraw']
  linear=np.where(baseline<=.04045,baseline/12.92,((baseline+.055)/1.055)**2.4).astype(np.float32)
  recovered=np.empty_like(linear);ip=linear.reshape(-1,3);op=recovered.reshape(-1,3)
  tp=table.ctypes.data_as(P);fp=film.ctypes.data_as(P)
  for i in range(len(ip)):
   if fn(ip[i].ctypes.data_as(P),tp,info['width'],info['height'],*info['start'],info['divisor'],1.,fp,len(film),op[i].ctypes.data_as(P))!=1:raise ValueError(f'Invalidpixel{pair}:{i}')
  clipped_fraction=float(np.mean((recovered<0)|(recovered>1)))
  rendered=srgb_encode(recovered)
  valid=original[pair]['libraw_baseline']['metrics']['color_space_established']
  bm=metrics(baseline,target,valid);rm=metrics(rendered,target,valid)
  image=np.uint8(np.clip(np.concatenate([target,baseline,rendered],axis=1),0,1)*255+.5)
  panel=Image.new('RGB',(image.shape[1],image.shape[0]+28),'white');panel.paste(Image.fromarray(image),(0,28));draw=ImageDraw.Draw(panel)
  for i,label in enumerate(['Published companion','LibRaw baseline','Recovered shared model + Standard']):draw.text((i*target.shape[1]+8,8),label,fill='black')
  path=folder/(pair+'-published-baseline-recovered.jpg');panel.save(path,quality=94)
  report={'pair_id':pair,'input_npz_sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'reference':original[pair]['reference'],'baseline':bm,'recovered':rm,'linear_components_clipped_at_export_fraction':clipped_fraction,'panel':str(path.relative_to(APP))}
  reports.append(report);print(pair,'baselineDE',bm['descriptive_deltaE76_D50']['median'],'recoveredDE',rm['descriptive_deltaE76_D50']['median'],flush=True)
result={'method':'Fixed portable C++ recovered chroma + native-domain Standard floorLUT + explicit gamma/nativeRGB bridge, no fitting or new registration','profile_id':info['profile_id'],'table_sha256':info['sha256'],'native_scale':1.,'strength':1.,'cube_approximation':False,'limitations':['Published companion processing/settings are undocumented; some carry Photoshop metadata','LibRaw independent sensor calibration and WB differ from Phocus','Previously registered downsampled sRGB baseline is decoded back to linear; resampling/8bit rounding predate this run','Fallback2007 Hasselblad chroma profile is not an identified camera-specific phone or modern Hasselblad calibration','Standard gamma decoding and Bradford bridge are explicit application integration choices','DeltaE76 is descriptive appearance residual, not chart ground truth or HNCS equivalence'],'results':reports}
(APP/'verification/public-image-results.json').write_text(json.dumps(result,indent=2)+'\n')
rows=[]
for r in reports:
 b=r['baseline'];n=r['recovered'];rows.append(f"| {r['pair_id']} | {b['descriptive_deltaE76_D50']['median']:.3f} | {n['descriptive_deltaE76_D50']['median']:.3f} | {b['lab_residual_components']['median_absolute_deltaL']:.3f} | {n['lab_residual_components']['median_absolute_deltaL']:.3f} | {b['lab_residual_components']['median_ab_vector_distance']:.3f} | {n['lab_residual_components']['median_ab_vector_distance']:.3f} |")
text='''# Application operator public-reference reality check

The portable application core was run directly on all three previously acquired and registered official Hasselblad RAW/companion pairs. No color, exposure, white-balance, or curve parameters were fitted to the companions. Input was the previously registered LibRaw baseline, decoded from sRGB to linear sRGB. Output used the selected recovered fallback chroma table, nativeScale1, recovered native-domain Standard film with **floor indexing**, declared native gamma decoding, nativeRGB-to-linear-sRGB bridge, and ordinary sRGB export. This directly evaluates the C++ per-pixel operator, without RGB-cube interpolation.

| Pair | Baseline median DE76 | Recovered median DE76 | Baseline median absΔL | Recovered median absΔL | Baseline median ab distance | Recovered median ab distance |
|---|---:|---:|---:|---:|---:|---:|
'''+ '\n'.join(rows)+'''

These are descriptive residuals against published appearances, not color-chart accuracy or controlled Phocus equivalence. A larger recovered residual means this fixed shared model moved that scene farther from the published rendering; a smaller one establishes only a closer appearance for that particular scene. No parameters were changed in response to the results.

The source processing settings are undocumented; sample02 has Photoshop metadata. LibRaw calibration differs from Phocus. The chosen2007 fallback profile is not a modern camera-specific profile. Prior downsampling, 8-bit sRGB rounding and grayscale-based alignment remain baked into the input arrays. The app's gamma/Bradford bridge is an explicit adaptation. Consequently these results cannot isolate the proprietary stages or establish HNCS equality.

Complete metrics, component residuals, source metadata and panel paths are in `/workspace/hassy-natural/verification/public-image-results.json`. Panels show published companion, LibRaw baseline, and recovered model from left to right in `/workspace/hassy-natural/verification/public-comparisons/`. Reproduce with `python3 /workspace/hassy-natural/verification/compare_public_hncs.py --lab /workspace/hncs-lab`. Requires numpy, Pillow, SciPy, a C++17 compiler and the existing lab arrays.
'''
(lab/'research/APP-REFERENCE-VALIDATION.md').write_text(text)
