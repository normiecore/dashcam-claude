"""Choose an existing iPhone runtime instead of assuming a runner image's SDK."""
import json,subprocess
r=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
candidates=[(runtime,d) for runtime,devices in r['devices'].items() if '.iOS-' in runtime for d in devices if d['name'].startswith('iPhone')]
if not candidates:raise SystemExit('No available iPhone simulator on this runner')
runtime,device=max(candidates,key=lambda pair:('iPhone 17 Pro'==pair[1]['name'],pair[0],pair[1]['name']))
print('SIM_UDID='+device['udid'])
