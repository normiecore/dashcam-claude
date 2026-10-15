"""Enroll only the user-requested existing Apple account; never log addresses.

Uses the already-configured team API key in GitHub Actions. The source stores
an address digest, not an email address. No other team members are enrolled.
"""
import hashlib,json,re,sys,urllib.error,urllib.parse,urllib.request
from apple_identity import BUNDLE,token

EXPECTED_TESTER_SHA256='64aa525f6d99078ca04c7138abadd37b927d32dddb3e006ec9607bc75b4f8200'
BASE='https://api.appstoreconnect.apple.com/v1/'
PRIVATE_VALUES=set()

def call(path,body=None):
    url=path if path.startswith(BASE) else BASE+path
    if not url.startswith(BASE):raise ValueError('Unexpected Apple API pagination origin')
    request=urllib.request.Request(url,data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization':'Bearer '+token(),'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(request,timeout=45) as response:
            data=response.read();return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        try:
            errors=json.loads(error.read()).get('errors',[])
            detail='; '.join(e.get('code','')+': '+e.get('detail',e.get('title','')) for e in errors)
            for value in sorted(PRIVATE_VALUES,key=len,reverse=True):
                if value:detail=detail.replace(value,'[private]')
            detail=re.sub(r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+','[email]',detail)
        except Exception:detail=''
        raise SystemExit(f'Apple tester enrollment HTTP {error.code} on {request.method} {urllib.parse.urlsplit(url).path}: {detail}') from None

def rows(path):
    while path:
        response=call(path)
        yield from response.get('data',[])
        path=response.get('links',{}).get('next')

def matches(address):
    return isinstance(address,str) and hashlib.sha256(address.strip().lower().encode()).hexdigest()==EXPECTED_TESTER_SHA256

def main():
    apps=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if len(apps)!=1:raise SystemExit('Expected one Hassy Natural app record')
    app_id=apps[0]['id']
    group=next((g for g in rows(f'apps/{app_id}/betaGroups?limit=200')
        if g['attributes']['isInternalGroup'] and g['attributes']['name']=='Hassy Natural Internal'),None)
    if group is None:
        group=call('betaGroups',{'data':{'type':'betaGroups','attributes':{
            'name':'Hassy Natural Internal','isInternalGroup':True,'hasAccessToAllBuilds':True,
            'feedbackEnabled':True},'relationships':{'app':{'data':{'type':'apps','id':app_id}}}}})['data']
        print('Created separate Hassy Natural internal group with build access')
    existing=list(rows(f'betaGroups/{group["id"]}/betaTesters?limit=200'))
    if not any(matches(t['attributes']['email']) for t in existing):
        user=next((u for u in rows('users?limit=200') if matches(u['attributes']['username'])),None)
        if user is None:
            raise SystemExit('The requested tester is not an existing App Store Connect team user. Add that account to Users and Access, then rerun enrollment without uploading again.')
        PRIVATE_VALUES.update(str(user['attributes'].get(k,'')) for k in ('username','firstName','lastName'))
        # Create/assign atomically by the existing team user's email. A tester
        # previously used by another app can have external status; linking that
        # tester ID directly to an internal group returns Apple's STATE_ERROR.
        call('betaTesters',{'data':{'type':'betaTesters','attributes':{
            'email':user['attributes']['username'],'firstName':user['attributes']['firstName'],
            'lastName':user['attributes']['lastName']},'relationships':{'betaGroups':{'data':[{'type':'betaGroups','id':group['id']}]}}}})
        assigned=list(rows(f'betaGroups/{group["id"]}/betaTesters?limit=200'))
        if not any(matches(t['attributes']['email']) for t in assigned):
            raise SystemExit('Apple accepted the tester request but group membership is not yet visible; rerun enrollment, not the upload')
    print('Requested user enrolled in Hassy Natural internal testing; no other accounts enrolled')
    builds=call('builds?'+urllib.parse.urlencode({'filter[app]':app_id,'sort':'-uploadedDate','limit':1}))['data']
    if builds:
        attrs=builds[0]['attributes']
        print('Latest Hassy Natural build:',attrs['version'],'Apple processing:',attrs['processingState'])
    else:print('Apple has not listed the uploaded build yet; do not repeat a successful upload')

if __name__=='__main__':main()
