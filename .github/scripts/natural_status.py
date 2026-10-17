"""Read-only confirmation of Apple processing and internal-group build access."""
import json,os,sys,time,urllib.parse,urllib.request
from pathlib import Path
sys.path.insert(0,str(Path('NaturalColor/ios/scripts').resolve()))
from apple_identity import BUNDLE,token
BASE='https://api.appstoreconnect.apple.com/v1/'
def get(path):
    request=urllib.request.Request(BASE+path,headers={'Authorization':'Bearer '+token()})
    with urllib.request.urlopen(request,timeout=45) as response:return json.load(response)
def main():
    apps=get('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if len(apps)!=1:raise SystemExit('Expected exactly one camera app record')
    app_id=apps[0]['id'];previous=None
    requested=os.environ.get('NATURAL_BUILD_NUMBER','')
    for attempt in range(70):
        builds=get('builds?'+urllib.parse.urlencode({'filter[app]':app_id,'sort':'-uploadedDate','limit':10}))['data']
        builds=[b for b in builds if not requested or b['attributes']['version']==requested]
        if builds:
            build=builds[0];attrs=build['attributes'];state=attrs['processingState']
            groups=get(f'apps/{app_id}/betaGroups?limit=200')['data']
            group=next((g for g in groups if g['attributes']['isInternalGroup'] and g['attributes']['name']=='Hassy Natural Internal'),None)
            assigned=False
            if group:
                assigned=any(b['id']==build['id'] for b in get(f'betaGroups/{group["id"]}/builds?limit=200')['data'])
            status=(attrs['version'],state,assigned)
            if status!=previous:print('Natural camera build:',attrs['version'],'processing:',state,'internal group access:',assigned,flush=True)
            previous=status
            if state in ('FAILED','INVALID'):raise SystemExit('Apple processing failed; inspect App Store Connect before another upload')
            if state=='VALID' and assigned:
                details=get(f'builds/{build["id"]}/buildBetaDetail')['data']['attributes']
                print('Internal TestFlight state:',details.get('internalBuildState','unspecified'),flush=True)
                print('Apple processing complete and build assigned to the existing internal group',flush=True)
                return
        elif previous is None:
            print('Waiting for Apple to list the requested camera build; this check never uploads',flush=True)
            previous='waiting'
        time.sleep(20)
    raise SystemExit('Apple processing/group access is still pending. Do not repeat a successful upload.')
if __name__=='__main__':main()
