"""Use CI-bound Apple credentials without displaying or exporting them.

Registers only the requested separate bundle identifier and reads its existing
App Store Connect record. Apple requires creating new app records on its website.
"""
import argparse,base64,json,os,subprocess,tempfile,time,urllib.error,urllib.parse,urllib.request
from pathlib import Path

BUNDLE='com.normiecore.hassynatural'

def b64(data):return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def raw_signature(der):
    def item(offset, expected):
        if der[offset]!=expected:raise ValueError('Unexpected ECDSA signature encoding')
        length=der[offset+1];start=offset+2
        if length&128:
            size=length&127;length=int.from_bytes(der[start:start+size],'big');start+=size
        return der[start:start+length],start+length
    _,offset=item(0,0x30)
    start=2 if der[1]<128 else 2+(der[1]&127)
    r,end=item(start,2);s,_=item(end,2)
    return int.from_bytes(r,'big').to_bytes(32,'big')+int.from_bytes(s,'big').to_bytes(32,'big')

def token():
    now=int(time.time())
    header=b64(json.dumps({'alg':'ES256','kid':os.environ['ASC_KEY_ID'],'typ':'JWT'},separators=(',',':')).encode())
    payload=b64(json.dumps({'iss':os.environ['ASC_ISSUER_ID'],'iat':now,'exp':now+600,'aud':'appstoreconnect-v1'},separators=(',',':')).encode())
    message=(header+'.'+payload).encode()
    with tempfile.TemporaryDirectory(prefix='natural-apple-key-') as temp:
        key=Path(temp)/'key.p8';key.write_text(os.environ['ASC_KEY_P8']);key.chmod(0o600)
        signature=subprocess.run(['openssl','dgst','-sha256','-sign',str(key)],input=message,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    return message.decode()+'.'+b64(raw_signature(signature))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--require-app',action='store_true');args=parser.parse_args()
    names=('ASC_KEY_ID','ASC_ISSUER_ID','ASC_KEY_P8','APPLE_TEAM_ID')
    missing=[name for name in names if not os.environ.get(name)]
    if missing:raise SystemExit('Missing CI secrets: '+', '.join(missing))
    jwt=token()
    def call(path,body=None):
        request=urllib.request.Request('https://api.appstoreconnect.apple.com/v1/'+path,
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization':'Bearer '+jwt,'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=45) as response:return json.load(response)
        except urllib.error.HTTPError as error:
            raise SystemExit(f'App Store Connect returned HTTP {error.code}; check the team API key role and current Apple agreements') from None
    bundle=call('bundleIds?'+urllib.parse.urlencode({'filter[identifier]':BUNDLE}))
    if not bundle['data']:
        call('bundleIds',{'data':{'type':'bundleIds','attributes':{'identifier':BUNDLE,'name':'Hassy Natural','platform':'IOS'}}})
        print('Registered separate Hassy Natural bundle identifier: '+BUNDLE)
    else:print('Separate Hassy Natural bundle identifier exists: '+BUNDLE)
    apps=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if apps:
        print('App Store Connect record exists for Hassy Natural: '+str(apps[0]['id']))
    else:
        message='Create Hassy Natural in App Store Connect > Apps > + > New App. Platform iOS; bundle '+BUNDLE+'; SKU hassy-natural-ios; primary language English (Australia).'
        print(message)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as out:out.write('### Hassy Natural app record\n\n'+message+'\n')
        if args.require_app:raise SystemExit('No separate Hassy Natural app record exists yet; refusing to upload as Dashcam.')

if __name__=='__main__':main()
