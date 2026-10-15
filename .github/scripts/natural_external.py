"""Inspect the requested app's public beta setup without exposing contacts."""
import json,sys,urllib.request,urllib.error,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path('NaturalColor/ios/scripts').resolve()))
from apple_identity import BUNDLE,token
BASE='https://api.appstoreconnect.apple.com/v1/'
def call(path,body=None,method=None):
    request=urllib.request.Request(BASE+path,data=None if body is None else json.dumps(body).encode(),method=method,
        headers={'Authorization':'Bearer '+token(),'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(request,timeout=45) as response:
            data=response.read();return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        try: detail=', '.join(x.get('code','')+' '+x.get('title','') for x in json.loads(e.read()).get('errors',[]))
        except Exception:detail=''
        raise RuntimeError(f'Apple HTTP {e.code} on {request.method} {path.split("?")[0]}: {detail}') from None

def main():
    apps=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if len(apps)!=1:raise SystemExit('Expected one Hassy Natural record')
    app=apps[0]['id'];print('Hassy Natural app:',app,flush=True)
    groups=call(f'apps/{app}/betaGroups?limit=200')['data']
    external=[g for g in groups if not g['attributes']['isInternalGroup']]
    for g in external:
        print('External group:',g['id'],g['attributes']['name'],'public link enabled:',g['attributes'].get('publicLinkEnabled'),flush=True)
    if len(external)==1:
        group=external[0]
        try:
            updated=call('betaGroups/'+group['id'],{'data':{'type':'betaGroups','id':group['id'],'attributes':{'publicLinkEnabled':True}}},'PATCH')['data']
            print('Public invitation link:',updated['attributes'].get('publicLink','not issued'),flush=True)
        except RuntimeError as e:print('Public link setup:',e,flush=True)
    review=call(f'apps/{app}/betaAppReviewDetail')['data']
    fields=('contactFirstName','contactLastName','contactPhone','contactEmail')
    print('Review contact fields present:',json.dumps({k:bool(review['attributes'].get(k)) for k in fields}),flush=True)
    localizations=call(f'apps/{app}/betaAppLocalizations?limit=200')['data']
    for loc in localizations:
        print('Beta app metadata:',loc['attributes'].get('locale'),json.dumps({k:bool(loc['attributes'].get(k)) for k in ('description','feedbackEmail','privacyPolicyUrl','marketingUrl')}),flush=True)
    builds=call('builds?'+urllib.parse.urlencode({'filter[app]':app,'sort':'-uploadedDate','limit':3}))['data']
    for b in builds:print('Build:',b['attributes'].get('version'),'audience:',b['attributes'].get('buildAudienceType'),'processing:',b['attributes'].get('processingState'),flush=True)
if __name__=='__main__':main()
