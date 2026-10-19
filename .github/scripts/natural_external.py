"""Inspect the requested app's public beta setup without exposing contacts."""
import json,os,re,sys,time,urllib.request,urllib.error,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path('NaturalColor/ios/scripts').resolve()))
from apple_identity import BUNDLE,token
BASE='https://api.appstoreconnect.apple.com/v1/'
PRIVATE_VALUES=set()
def call(path,body=None,method=None):
    request=urllib.request.Request(BASE+path,data=None if body is None else json.dumps(body).encode(),method=method,
        headers={'Authorization':'Bearer '+token(),'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(request,timeout=45) as response:
            data=response.read();result=json.loads(data) if data else {}
            entries=result.get('data',[]) if isinstance(result,dict) else []
            if isinstance(entries,dict):entries=[entries]
            for entry in entries:
                for key,value in entry.get('attributes',{}).items():
                    if key in ('contactFirstName','contactLastName','contactEmail','contactPhone','feedbackEmail') and value:
                        PRIVATE_VALUES.add(str(value))
            return result
    except urllib.error.HTTPError as e:
        try:
            detail='; '.join(x.get('code','')+' '+x.get('detail',x.get('title','')) for x in json.loads(e.read()).get('errors',[]))
            for value in sorted(PRIVATE_VALUES,key=len,reverse=True):detail=detail.replace(value,'[private]')
            detail=re.sub(r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+','[email]',detail)
            detail=re.sub(r'\+?\d[\d ()-]{7,}\d','[number]',detail)
        except Exception:detail=''
        raise RuntimeError(f'Apple HTTP {e.code} on {request.get_method()} {path.split("?")[0]}: {detail}') from None

def main():
    apps=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if len(apps)!=1:raise SystemExit('Expected one camera app record')
    app=apps[0]['id'];print('Natural camera app:',app,flush=True)
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
def distribute():
    app=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data'][0]['id']
    groups=[g for g in call(f'apps/{app}/betaGroups?limit=200')['data'] if not g['attributes']['isInternalGroup']]
    if len(groups)!=1:raise SystemExit('Select exactly one external beta group before distributing')
    group=groups[0];requested=os.environ.get('NATURAL_BUILD_NUMBER','')
    build=None
    for attempt in range(80):
        builds=call('builds?'+urllib.parse.urlencode({'filter[app]':app,'sort':'-uploadedDate','limit':10}))['data']
        build=next((b for b in builds if (not requested or b['attributes']['version']==requested)
            and b['attributes'].get('buildAudienceType')=='APP_STORE_ELIGIBLE'),None)
        if build:
            state=build['attributes']['processingState']
            if state in ('FAILED','INVALID'):raise SystemExit('External build processing failed; inspect Apple before another upload')
            if state=='VALID':break
        if attempt%6==0:print('Waiting for the external-eligible build to finish Apple processing',flush=True)
        time.sleep(15)
    else:raise SystemExit('Apple processing is pending; rerun distribution without uploading another build')
    print('External-eligible build:',build['attributes']['version'],'processing VALID',flush=True)
    locs=call(f'apps/{app}/betaAppLocalizations?limit=200')['data']
    description=('Open straight to the camera, choose a frame and take the photo. Finished photos save directly to Photos. '
        'Simple mode keeps the essentials close; Advanced mode adds exposure readings, compensation and a grid. '
        'Native framing preserves the supported capture dimensions. HEIC Medium is the default, with JPEG and '
        'other compression settings available. RAW + processed saving is optional on supported cameras. '
        'Import JPEG, HEIC or supported RAW files to adjust exposure and finishing, compare, save and share. '
        'Processing takes place on your iPhone. No account is required.')
    if locs:
        loc=next((x for x in locs if x['attributes'].get('locale')=='en-AU'),locs[0])
        call('betaAppLocalizations/'+loc['id'],{'data':{'type':'betaAppLocalizations','id':loc['id'],'attributes':{'description':description}}},'PATCH')
    else:
        call('betaAppLocalizations',{'data':{'type':'betaAppLocalizations','attributes':{'locale':'en-AU','description':description},
            'relationships':{'app':{'data':{'type':'apps','id':app}}}}})
    notes=('Natural 0.1.4: smoother bright-sky highlights and a restrained foreground lift in backlit RAW scenes. '
        'The preferred colour rendering remains, with Display P3 HEIC retaining colours outside sRGB. '
        'High-contrast HEIC includes an HDR gain map on iOS 26 and later; JPEG remains SDR. '
        'Photos now record rendering build/settings so feedback can identify the exact pipeline. '
        'Save RAW original still controls retention only on ProRAW-capable cameras. '
        'Please check backlit foreground detail, sky transitions, foliage and skin colour in Photos, '
        'plus repeated captures, lens switches, RAW-saving toggle parity and failed-save recovery. '
        'This is an experimental photographic update; calibrated X2D II equivalence has not been established. '
        'Report crashes, save failures or unexpected rendering through TestFlight.')
    existing=call(f'builds/{build["id"]}/betaBuildLocalizations?limit=200')['data']
    if existing:
        loc=existing[0]
        call('betaBuildLocalizations/'+loc['id'],{'data':{'type':'betaBuildLocalizations','id':loc['id'],'attributes':{'whatsNew':notes}}},'PATCH')
    else:
        call('betaBuildLocalizations',{'data':{'type':'betaBuildLocalizations','attributes':{'locale':'en-AU','whatsNew':notes},
            'relationships':{'build':{'data':{'type':'builds','id':build['id']}}}}})
    review=call(f'apps/{app}/betaAppReviewDetail')['data']
    missing=[k for k in ('contactFirstName','contactLastName','contactPhone','contactEmail') if not review['attributes'].get(k)]
    locs=call(f'apps/{app}/betaAppLocalizations?limit=200')['data']
    if not any(x['attributes'].get('feedbackEmail') for x in locs):missing.append('feedbackEmail')
    if missing:print('Review metadata fields currently empty:',', '.join(missing),flush=True)
    if review['attributes'].get('demoAccountRequired'):
        call('betaAppReviewDetails/'+review['id'],{'data':{'type':'betaAppReviewDetails','id':review['id'],
            'attributes':{'demoAccountRequired':False,'notes':'No login is needed. Import a photo or allow camera access, edit, and export.'}}},'PATCH')
    beta=call(f'builds/{build["id"]}/buildBetaDetail')['data']
    call('buildBetaDetails/'+beta['id'],{'data':{'type':'buildBetaDetails','id':beta['id'],'attributes':{'autoNotifyEnabled':True}}},'PATCH')
    assigned=call(f'betaGroups/{group["id"]}/builds?limit=200')['data']
    if not any(b['id']==build['id'] for b in assigned):
        try:
            call('betaGroups/'+group['id']+'/relationships/builds',{'data':[{'type':'builds','id':build['id']}]})
            print('External build assigned to the existing public group',flush=True)
        except RuntimeError as error:print('Group assignment status:',error,flush=True)
    state=call(f'builds/{build["id"]}/buildBetaDetail')['data']['attributes']['externalBuildState']
    print('External testing state before submission:',state,flush=True)
    if missing:
        updated=call('betaGroups/'+group['id'],{'data':{'type':'betaGroups','id':group['id'],'attributes':{'publicLinkEnabled':True}}},'PATCH')['data']
        print('Public invitation link:',updated['attributes'].get('publicLink'),flush=True)
        print('Public Beta App Review is not submitted: awaiting user-provided review contact and feedback information.',flush=True)
        from natural_status import main as confirm_internal_access
        confirm_internal_access()
        return
    if state=='READY_FOR_BETA_SUBMISSION':
        try:
            call('betaAppReviewSubmissions',{'data':{'type':'betaAppReviewSubmissions','relationships':{'build':{'data':{'type':'builds','id':build['id']}}}}})
            print('Submitted the external build for Apple Beta App Review',flush=True)
        except RuntimeError as error:
            if 'ANOTHER_BUILD_IN_REVIEW' not in str(error):raise
            print('External Beta App Review submission is pending: another build in this version is still in review. '
                  'Retry distribution after that review completes; do not upload this build again.',flush=True)
    elif state in ('WAITING_FOR_BETA_REVIEW','IN_BETA_REVIEW','IN_BETA_TESTING','BETA_APPROVED','READY_FOR_BETA_TESTING'):
        print('External build already has review/distribution state:',state,flush=True)
    else:print('External state needs attention in App Store Connect:',state,flush=True)
    assigned=call(f'betaGroups/{group["id"]}/builds?limit=200')['data']
    if not any(b['id']==build['id'] for b in assigned):
        call('betaGroups/'+group['id']+'/relationships/builds',{'data':[{'type':'builds','id':build['id']}]})
    updated=call('betaGroups/'+group['id'],{'data':{'type':'betaGroups','id':group['id'],'attributes':{'publicLinkEnabled':True}}},'PATCH')['data']
    print('Public invitation link:',updated['attributes'].get('publicLink'),flush=True)
    print('Apple must approve the external beta before public testers can install it',flush=True)
    from natural_status import main as confirm_internal_access
    confirm_internal_access()
if __name__=='__main__':
    distribute() if len(sys.argv)>1 and sys.argv[1]=='distribute' else main()

