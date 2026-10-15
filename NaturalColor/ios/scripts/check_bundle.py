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
assert (p/'StandardCurve.f32').stat().st_size==65536*4,'Missing recovered film curve'
print('Production Hassy Natural bundle checks pass')
