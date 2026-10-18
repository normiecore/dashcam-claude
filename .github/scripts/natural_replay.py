"""Private native replay audit; photographs and authenticated references never logged."""
import base64, hashlib, json, os, re, shutil, subprocess, sys, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
ROOT=Path(os.environ['RUNNER_TEMP'])/'natural-replay'
CONTEXT=b'com.normiecore.hassynatural/private-replay/input/v1'
OUTPUT=b'com.normiecore.hassynatural/private-replay/output/v1'
OLD='5365cfa6f202c023132ab4fd6cb95d4859d3564f'
CURRENT='0d405590144995297c5d4ab1faa9bb2beebccc66'
ENGINE='NaturalColor/ios/HassyNatural/Imaging/PhotoEngine.swift'
def key(shared,salt,context):
    return HKDF(algorithm=hashes.SHA256(),length=32,salt=salt,info=context).derive(shared)
def source_snapshot(commit,prefix):
    source=subprocess.check_output(['git','show',commit+':'+ENGINE]).decode()
    helper='''
    func auditFullRaster(photo: LoadedPhoto, settings: EditSettings) throws -> CGImage {
        let image = try filtered(crop(photo.image, ratio: settings.aspectRatio), settings: settings)
        guard let raster = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else { throw PhotoError.rendering }
        return raster
    }
'''
    source=source.replace('\n}\n\nprivate struct ReferenceProfile:',helper+'\n}\n\nprivate struct ReferenceProfile:')
    for name in ['PhotoEngine','EditSettings','PhotoError','LoadedPhoto','ReferenceProfile','ReferenceAssets']:
        source=re.sub(r'\b'+name+r'\b',prefix+name,source)
    # Prefix Swift identifiers, preserving the on-disk resource name literal.
    source=source.replace(chr(34)+prefix+'ReferenceProfile'+chr(34),chr(34)+'ReferenceProfile'+chr(34))
    assert 'data("ReferenceProfile", "json")' in source
    assert chr(34)+prefix+'ReferenceProfile'+chr(34) not in source
    return '@testable import HassyNatural\n'+source

def prepare():
    ROOT.mkdir(parents=True,exist_ok=True)
    e=json.loads(Path('.github/replay-input.enc.json').read_text())
    private=serialization.load_pem_private_key(os.environ['ASC_KEY_P8'].encode(),password=None)
    public=private.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
    if e['recipient_sha256']!=hashlib.sha256(public).hexdigest():raise ValueError('recipient')
    peer=serialization.load_der_public_key(base64.b64decode(e['ephemeral_public_key']))
    secret=key(private.exchange(ec.ECDH(),peer),base64.b64decode(e['salt']),CONTEXT)
    spec=json.loads(AESGCM(secret).decrypt(base64.b64decode(e['nonce']),base64.b64decode(e['ciphertext']),CONTEXT))
    fixtures=Path('NaturalColor/ios/HassyNaturalTests/Fixtures');fixtures.mkdir(parents=True,exist_ok=True)
    def download(item):
        if item['id'] not in ['scene-a','scene-b']:raise ValueError('input name')
        for kind in ['dng','heic']:
            destination=fixtures/(item['id']+'.'+kind)
            with urllib.request.urlopen(item[kind]['url'],timeout=120) as response, destination.open('wb') as output:
                shutil.copyfileobj(response,output)
            if hashlib.sha256(destination.read_bytes()).hexdigest()!=item[kind]['sha256']:raise ValueError('checksum')
    with ThreadPoolExecutor(max_workers=2) as executor:list(executor.map(download,spec['inputs']))
    (ROOT/'return-public.der').write_bytes(base64.b64decode(spec['return_public_key']))
    safe=[{'id':x['id'],'dng_sha256':x['dng']['sha256'],'actual_heic_sha256':x['heic']['sha256']} for x in spec['inputs']]
    (fixtures/'replay-manifest.json').write_text(json.dumps(safe))
    tests=Path('NaturalColor/ios/HassyNaturalTests')
    (tests/'LegacyReplayEngine.swift').write_text(source_snapshot(OLD,'Legacy'))
    (tests/'CurrentReplayEngine.swift').write_text(source_snapshot(CURRENT,'Current'))
    (tests/'PrivateNativeReplayTests.swift').write_text(SWIFT)
    print('Two private RAW and actual HEIC pairs verified. References and photographs omitted from logs.')

def seal():
    log=(Path(os.environ['RUNNER_TEMP'])/'replay-native.log').read_text()
    paths=re.findall(r'NATIVE_REPLAY_DIRECTORY=(/[^\r\n]+)',log)
    if not paths:raise ValueError('output directory missing')
    directory=Path(paths[-1].strip())
    manifest=directory/'render-manifest.json'
    if not manifest.is_file():raise ValueError('manifest missing')
    spec=json.loads(manifest.read_text())
    for row in spec:
        row['files']={p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in directory.glob(row['id']+'-*')}
    manifest.write_text(json.dumps({'legacy_app_source':OLD,'current_app_source':CURRENT,'mode':'native iOS simulator same-input replay; no phone recapture','settings':{'strength':1,'exposure':0,'aspect':'native','legacy_jpeg_quality':0.96,'current_jpeg_quality':0.95,'current_heic_quality':0.78},'canonical_comparison':'Decoded native outputs transformed to sRGB RGBA8, long edge 1600, orientation applied. JPEG previews carry embedded sRGB profile. No creative edit.','renders':spec},indent=2))
    archive=ROOT/'outputs.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED) as z:
        for p in directory.iterdir():z.write(p,p.name)
    recipient=serialization.load_der_public_key((ROOT/'return-public.der').read_bytes())
    ephemeral=ec.generate_private_key(ec.SECP256R1());salt=os.urandom(32);nonce=os.urandom(12)
    secret=key(ephemeral.exchange(ec.ECDH(),recipient),salt,OUTPUT)
    ciphertext=AESGCM(secret).encrypt(nonce,archive.read_bytes(),OUTPUT)
    envelope={k:base64.b64encode(v).decode() for k,v in {'ephemeral_public_key':ephemeral.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo),'salt':salt,'nonce':nonce}.items()}
    chunk=20*1024*1024
    envelope['ciphertext_bytes']=len(ciphertext)
    envelope['parts']=(len(ciphertext)+chunk-1)//chunk
    if envelope['parts']>8:raise ValueError('output exceeds upload capacity')
    (ROOT/'output-envelope.json').write_text(json.dumps(envelope))
    for i,start in enumerate(range(0,len(ciphertext),chunk)):(ROOT/f'output-{i:02d}.enc').write_bytes(ciphertext[start:start+chunk])
    print('Encrypted evidence parts='+str(envelope['parts'])+' bytes='+str(len(ciphertext)))
    archive.unlink();shutil.rmtree(directory)
    print('Native replays and canonical comparison derivatives sealed; only ciphertext uploaded.')
SWIFT=r'''import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import HassyNatural

final class PrivateNativeReplayTests: XCTestCase {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    lazy var context = CIContext(options: [.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates:false])
    func hash(_ image: CGImage) throws -> String {
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        return SHA256.hash(data:bytes as Data).map { String(format:"%02x",$0) }.joined()
    }
    func canonical(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600] as CFDictionary))
        let image = CIImage(cgImage:decoded)
        return try XCTUnwrap(context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:srgb))
    }
    func save(_ image: CGImage, _ url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.96,kCGImagePropertyOrientation:1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func stats(_ a: CGImage, _ b: CGImage) throws -> [String:Any] {
        guard a.width == b.width && a.height == b.height else { return ["dimensions_match":false,"a_width":a.width,"a_height":a.height,"b_width":b.width,"b_height":b.height] }
        let aa = [UInt8](try XCTUnwrap(a.dataProvider?.data) as Data), bb = [UInt8](try XCTUnwrap(b.dataProvider?.data) as Data)
        var total=0.0, square=0.0, maxError=0, count=0, clippedA=0,clippedB=0
        var hist=[Int](repeating:0,count:256)
        for y in 0..<a.height { for x in 0..<a.width {
            let ia=y*a.bytesPerRow+x*4, ib=y*b.bytesPerRow+x*4
            for c in 0..<3 {
                let delta=abs(Int(aa[ia+c])-Int(bb[ib+c]));total += Double(delta);square += Double(delta*delta);maxError=max(maxError,delta);hist[delta]+=1;count+=1
                if aa[ia+c] == 255 {clippedA+=1};if bb[ib+c] == 255 {clippedB+=1}
            }
        } }
        var cumulative=0,p95=0
        for n in 0..<256 {cumulative += hist[n];if Double(cumulative)>=Double(count)*0.95 {p95=n;break}}
        return ["dimensions_match":true,"mae_code_values":total/Double(count),"rmse_code_values":sqrt(square/Double(count)),"p95_absolute_code_values":p95,"max_absolute_code_values":maxError,"clipped255_fraction_a":Double(clippedA)/Double(count),"clipped255_fraction_b":Double(clippedB)/Double(count)]
    }
    func properties(_ url: URL) throws -> [String:Any] {
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let p=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        return ["width":image.width,"height":image.height,"profile_name":p[kCGImagePropertyProfileName] as? String ?? "none","color_space_name":image.colorSpace?.name as String? ?? "none","orientation":p[kCGImagePropertyOrientation] as? Int ?? 1]
    }
    func testReplayTwoRound3Pairs() async throws {
        executionTimeAllowance=900
        let fixture=try XCTUnwrap(Bundle(for:Self.self).resourceURL?.appendingPathComponent("Fixtures"))
        let inputs=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("replay-manifest.json"))) as? [[String:String]])
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Replay")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let legacy=LegacyPhotoEngine(),current=PhotoEngine(),audited=CurrentPhotoEngine()
        var manifest=[[String:Any]]()
        for item in inputs {
            let id=try XCTUnwrap(item["id"]),raw=fixture.appendingPathComponent(id+".dng"),actual=fixture.appendingPathComponent(id+".heic")
            let oldPhoto=try await legacy.load(url:raw),newPhoto=try await current.load(url:raw),auditPhoto=try await audited.load(url:raw)
            print("NATIVE_REPLAY_STAGE="+id+"-loaded")
            let oldPreview=try await legacy.preview(photo:oldPhoto,settings:.init()),newPreview=try await current.preview(photo:newPhoto,settings:.init())
            let oldPreviewHash=try hash(oldPreview),newPreviewHash=try hash(newPreview)
            XCTAssertEqual(oldPreviewHash,newPreviewHash,"Restored current preview must match original on same RAW")
            let oldOriginal=try await legacy.preview(photo:oldPhoto,settings:.init(),original:true),newOriginal=try await current.preview(photo:newPhoto,settings:.init(),original:true)
            XCTAssertEqual(try hash(oldOriginal),try hash(newOriginal))
            let auditedPreview=try await audited.preview(photo:auditPhoto,settings:.init())
            XCTAssertEqual(try hash(auditedPreview),newPreviewHash,"Instrumented source snapshot must match live app")
            print("NATIVE_REPLAY_STAGE="+id+"-preview-parity")
            let oldRasterHash=try await hash(legacy.auditFullRaster(photo:oldPhoto,settings:.init()))
            let currentRasterHash=try await hash(audited.auditFullRaster(photo:auditPhoto,settings:.init()))
            XCTAssertEqual(oldRasterHash,currentRasterHash,"Full-resolution pre-encoding sRGB raster must match original")
            print("NATIVE_REPLAY_STAGE="+id+"-full-raster-parity")
            try save(oldPreview,directory.appendingPathComponent(id+"-legacy-preview.jpg"))
            try save(newPreview,directory.appendingPathComponent(id+"-current-preview.jpg"))
            try save(newOriginal,directory.appendingPathComponent(id+"-decoder-zero-strength.jpg"))
            let old=try await legacy.export(photo:oldPhoto,settings:.init())
            let jpeg=try await current.export(photo:newPhoto,settings:.init(),output:.init(format:.jpeg,quality:.high))
            let heic=try await current.export(photo:newPhoto,settings:.init(),output:.init())
            XCTAssertEqual(heic.pathExtension,"heic","Native HEIC encoding is required")
            print("NATIVE_REPLAY_STAGE="+id+"-native-exports")
            let files=[("legacy-native.jpg",old),("current-native.jpg",jpeg),("current-native.heic",heic)]
            for (suffix,url) in files {try FileManager.default.copyItem(at:url,to:directory.appendingPathComponent(id+"-"+suffix))}
            let oldDecoded=try canonical(old),jpegDecoded=try canonical(jpeg),heicDecoded=try canonical(heic),actualDecoded=try canonical(actual)
            for (suffix,image) in [("legacy-decoded.jpg",oldDecoded),("current-jpeg-decoded.jpg",jpegDecoded),("current-heic-decoded.jpg",heicDecoded),("actual-r3-decoded.jpg",actualDecoded)] {try save(image,directory.appendingPathComponent(id+"-"+suffix))}
            manifest.append(["id":id,"dng_sha256":item["dng_sha256"]!,"actual_heic_sha256":item["actual_heic_sha256"]!,"legacy_preview_sha256":oldPreviewHash,"current_preview_sha256":newPreviewHash,"legacy_full_srgb_raster_sha256":oldRasterHash,"current_full_srgb_raster_sha256":currentRasterHash,"legacy_vs_current_jpeg":try stats(oldDecoded,jpegDecoded),"legacy_vs_current_heic":try stats(oldDecoded,heicDecoded),"actual_r3_vs_replayed_heic":try stats(actualDecoded,heicDecoded),"legacy_properties":try properties(old),"current_jpeg_properties":try properties(jpeg),"current_heic_properties":try properties(heic),"actual_properties":try properties(actual)])
            print("NATIVE_REPLAY_STAGE="+id+"-metrics-complete")
            for (_,url) in files {try? FileManager.default.removeItem(at:url)}
        }
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:directory.appendingPathComponent("render-manifest.json"))
        print("NATIVE_REPLAY_DIRECTORY="+directory.path)
    }
}
'''
if __name__=='__main__':
    try:
        if sys.argv[1]=='prepare':prepare()
        else:seal()
    except Exception:
        raise SystemExit('Private replay failed. No private inputs printed; inspect source assertions or refresh private references.') from None
