import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);d=plistlib.loads((p/'Info.plist').read_bytes())
assert d['CFBundleIdentifier']=='com.normiecore.hassynatural','Incorrect app identity'
assert d['UIDeviceFamily']==[1],'Expected iPhone-only build'
for key in ['NSCameraUsageDescription','NSPhotoLibraryAddUsageDescription','CFBundleVersion','CFBundleShortVersionString']:
 assert d[key],key
assert (p/'PrivacyInfo.xcprivacy').exists(),'Missing privacy manifest'
assert (p/'Assets.car').exists(),'Missing compiled icon assets'
assert (p/'HassyNatural').exists(),'Missing executable'
assert d['CFBundleDisplayName']=='Natural','Incorrect display name'
# Restored 0.1.1 rendering resources must be present and unchanged.
import hashlib,json
profile=json.loads((p/'ReferenceProfile.json').read_text())
chroma=(p/'ReferenceChroma.f32').read_bytes()
film=(p/'StandardCurve.f32').read_bytes()
assert len(chroma)==profile['width']*profile['height']*2*4,'Incorrect chroma table dimensions'
assert hashlib.sha256(chroma).hexdigest()==profile['sha256'],'Chroma table hash mismatch'
assert len(film)==65536*4,'Incorrect film curve dimensions'
assert hashlib.sha256(film).hexdigest()=='b3324e976976df34b5f6ecbd4c4e6830a68b1b1a75c573a0800ef6f144e29598','Film curve hash mismatch'
assert (p/'default.metallib').exists(),'Missing rendering kernel'
print('Production Natural bundle checks pass: restored renderer and verified tables')
