"""Private artwork verification: authenticated encrypted inputs and encrypted outputs only."""
import base64, hashlib, json, os, re, shutil, sys, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
ROOT=Path(os.environ['RUNNER_TEMP'])/'natural-artwork'
CONTEXT=b'com.normiecore.hassynatural/private-artwork/input/v1'
OUTPUT=b'com.normiecore.hassynatural/private-artwork/output/v1'
def key(shared,salt,context):
    return HKDF(algorithm=hashes.SHA256(),length=32,salt=salt,info=context).derive(shared)
def prepare():
    ROOT.mkdir(parents=True,exist_ok=True)
    e=json.loads(Path('.github/artwork-input.enc.json').read_text())
    private=serialization.load_pem_private_key(os.environ['ASC_KEY_P8'].encode(),password=None)
    public=private.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
    if e['recipient_sha256']!=hashlib.sha256(public).hexdigest():raise ValueError('recipient')
    peer=serialization.load_der_public_key(base64.b64decode(e['ephemeral_public_key']))
    secret=key(private.exchange(ec.ECDH(),peer),base64.b64decode(e['salt']),CONTEXT)
    spec=json.loads(AESGCM(secret).decrypt(base64.b64decode(e['nonce']),base64.b64decode(e['ciphertext']),CONTEXT))
    fixtures=Path('NaturalColor/ios/HassyNaturalTests/Fixtures');fixtures.mkdir(parents=True,exist_ok=True)
    def download(item):
        if item['id'] not in ['fronds','pennants','sculpture','tower']:raise ValueError('input name')
        destination=fixtures/(item['id']+'.dng')
        with urllib.request.urlopen(item['url'],timeout=120) as response, destination.open('wb') as output:
            shutil.copyfileobj(response,output)
        if hashlib.sha256(destination.read_bytes()).hexdigest()!=item['sha256']:raise ValueError('checksum')
    with ThreadPoolExecutor(max_workers=4) as executor:list(executor.map(download,spec['inputs']))
    (ROOT/'return-public.der').write_bytes(base64.b64decode(spec['return_public_key']))
    safe=[{'id':x['id'],'source_sha256':x['sha256']} for x in spec['inputs']]
    (fixtures/'artwork-manifest.json').write_text(json.dumps(safe))
    Path('NaturalColor/ios/HassyNaturalTests/PrivateArtworkRenderingTests.swift').write_text(SWIFT)
    print('Four private RAW fixtures verified. URLs and photographs omitted from logs.')
def seal():
    # The test reports its authoritative host-accessible Simulator path.
    # Xcode may shut the Simulator down before the collection step.
    log=(Path(os.environ['RUNNER_TEMP'])/'artwork-native.log').read_text()
    paths=re.findall(r'NATIVE_ARTWORK_DIRECTORY=(/[^\r\n]+)',log)
    if not paths:raise ValueError('output directory missing')
    directory=Path(paths[-1].strip())
    if not (directory/'render-manifest.json').is_file():raise ValueError('manifest missing')
    files=list(directory.iterdir())
    if len([x for x in files if x.suffix=='.heic'])!=4 or len([x for x in files if x.suffix=='.jpg'])!=4:raise ValueError('incomplete output')
    spec=json.loads((directory/'render-manifest.json').read_text())
    for row in spec:
        for kind in ['heic','jpg']:
            p=directory/(row['id']+'.'+kind);row[kind+'_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
    (directory/'render-manifest.json').write_text(json.dumps({'verified_app_source':'9744adf493c837c32f8663ac14f5aef04511ff5f','engine':'iOS PhotoEngine + NaturalKernel, unmodified 0.1.2 source','settings':{'strength':1,'exposure':0,'aspect':'native','format':'HEIC','quality':'Medium (0.78)'},'presentation':'JPEG thumbnails decoded from the final encoded HEICs, maximum edge 2400; no additional grading','renders':spec},indent=2))
    archive=ROOT/'outputs.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED) as z:
        for p in directory.iterdir():z.write(p,p.name)
    recipient=serialization.load_der_public_key((ROOT/'return-public.der').read_bytes())
    ephemeral=ec.generate_private_key(ec.SECP256R1());salt=os.urandom(32);nonce=os.urandom(12)
    secret=key(ephemeral.exchange(ec.ECDH(),recipient),salt,OUTPUT)
    ciphertext=AESGCM(secret).encrypt(nonce,archive.read_bytes(),OUTPUT)
    envelope={k:base64.b64encode(v).decode() for k,v in {'ephemeral_public_key':ephemeral.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo),'salt':salt,'nonce':nonce}.items()}
    (ROOT/'output-envelope.json').write_text(json.dumps(envelope));(ROOT/'output.enc').write_bytes(ciphertext)
    archive.unlink();shutil.rmtree(directory)
    print('Four native HEIC exports and their presentation derivatives sealed. Only ciphertext is uploaded.')
SWIFT=r'''import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import HassyNatural

final class PrivateArtworkRenderingTests: XCTestCase {
    func testRenderPrivateSelections() async throws {
        executionTimeAllowance = 600
        let fixture = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Fixtures"))
        let inputs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("artwork-manifest.json"))) as? [[String:String]])
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = PhotoEngine()
        var manifest = [[String:Any]]()
        for item in inputs {
            let id = try XCTUnwrap(item["id"])
            let file = try await engine.exportCapture(url: fixture.appendingPathComponent(id+".dng"), settings: .init(), output: .init())
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(file.pathExtension, "heic", "Native HEIC encoding is required for this evidence")
            let heic = directory.appendingPathComponent(id+".heic")
            try FileManager.default.copyItem(at: file, to: heic)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(heic as CFURL,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
            XCTAssertEqual(width*height,8064*6048)
            let preview = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2400] as CFDictionary))
            let jpg = directory.appendingPathComponent(id+".jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpg as CFURL,UTType.jpeg.identifier as CFString,1,nil))
            CGImageDestinationAddImage(destination,preview,[kCGImageDestinationLossyCompressionQuality:0.95,kCGImagePropertyOrientation:1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            manifest.append(["id":id,"source_sha256":item["source_sha256"]!,"width":width,"height":height,"preview_width":preview.width,"preview_height":preview.height])
        }
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:directory.appendingPathComponent("render-manifest.json"))
        print("NATIVE_ARTWORK_DIRECTORY=" + directory.path)
    }
}
'''
if __name__=='__main__':
    try:
        if sys.argv[1]=='prepare':prepare()
        else:seal()
    except Exception:
        # Exceptions from HTTP/crypto may contain private URLs or payload fields.
        raise SystemExit('Private artwork operation failed. No private inputs printed; refresh authenticated inputs if expired.') from None
