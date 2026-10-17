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
for name in ['ReferenceChroma.f32','ReferenceProfile.json','StandardCurve.f32','StandardCurve.provenance.json','HNCSMatrix.provenance.json']:
 assert not list(p.rglob(name)),f'Research resource must not be distributed: {name}'
assert (p/'default.metallib').exists(),'Missing independent finishing kernel' 
print('Production Natural bundle checks pass')
