"""Apply user-supplied review information from an encrypted contact envelope.

Only the public encryption key, field names and submission state may be logged.
The Apple API private key stays in GitHub Actions secrets. No contact plaintext
is stored in repository files, artifacts or workflow output.
"""
import base64,hashlib,json,os,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path('.github/scripts').resolve()))
from natural_external import BUNDLE,PRIVATE_VALUES,call,distribute
CONTEXT=(BUNDLE+'/review-contact/v1').encode()
ENVELOPE=Path('.github/review-contact.enc.json')

def public_key_der():
    return subprocess.run(['openssl','pkey','-pubout','-outform','DER'],input=os.environ['ASC_KEY_P8'].encode(),
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout

def main():
    public=public_key_der()
    if not ENVELOPE.exists():
        print('CONTACT_ENCRYPTION_PUBLIC_KEY='+base64.b64encode(public).decode())
        print('No contact envelope supplied; no Apple metadata changed.')
        return
    from cryptography.hazmat.primitives import hashes,serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    envelope=json.loads(ENVELOPE.read_text())
    if envelope.get('version')!=1 or envelope.get('recipient_sha256')!=hashlib.sha256(public).hexdigest():
        raise SystemExit('Contact envelope does not match the configured encryption recipient')
    private=serialization.load_pem_private_key(os.environ['ASC_KEY_P8'].encode(),password=None)
    peer=serialization.load_der_public_key(base64.b64decode(envelope['ephemeral_public_key']))
    if not isinstance(peer,ec.EllipticCurvePublicKey) or peer.curve.name!='secp256r1':
        raise SystemExit('Unsupported contact encryption key')
    shared=private.exchange(ec.ECDH(),peer)
    key=HKDF(algorithm=hashes.SHA256(),length=32,salt=base64.b64decode(envelope['salt']),info=CONTEXT).derive(shared)
    plaintext=AESGCM(key).decrypt(base64.b64decode(envelope['nonce']),base64.b64decode(envelope['ciphertext']),CONTEXT)
    contact=json.loads(plaintext)
    fields=('contactFirstName','contactLastName','contactPhone','contactEmail','feedbackEmail')
    if set(contact)!=set(fields) or not all(isinstance(contact[k],str) and contact[k].strip() for k in fields):
        raise SystemExit('Required review-contact fields are missing from the encrypted envelope')
    PRIVATE_VALUES.update(contact.values())
    import urllib.parse
    apps=call('apps?'+urllib.parse.urlencode({'filter[bundleId]':BUNDLE}))['data']
    if len(apps)!=1 or apps[0]['id']!='6823073017':raise SystemExit('Unexpected target app record')
    app=apps[0]['id']
    review=call(f'apps/{app}/betaAppReviewDetail')['data']
    attributes={k:contact[k] for k in fields if k!='feedbackEmail'}
    attributes.update(demoAccountRequired=False,notes='No login is required. Allow camera access or import a photo, adjust strength/exposure, compare and export.')
    call('betaAppReviewDetails/'+review['id'],{'data':{'type':'betaAppReviewDetails','id':review['id'],'attributes':attributes}},'PATCH')
    locs=call(f'apps/{app}/betaAppLocalizations?limit=200')['data']
    if not locs:raise SystemExit('Create the beta description before applying feedback information')
    for loc in locs:
        call('betaAppLocalizations/'+loc['id'],{'data':{'type':'betaAppLocalizations','id':loc['id'],
            'attributes':{'feedbackEmail':contact['feedbackEmail']}}},'PATCH')
    print('Saved the user-provided Apple review contact and tester feedback address; values omitted from logs.',flush=True)
    distribute()
if __name__=='__main__':main()
