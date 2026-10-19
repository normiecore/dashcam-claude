"""Private native pre-film float capture; no calibration or graded candidate is authored."""
import base64,hashlib,json,os,re,shutil,subprocess,sys,time,urllib.error,urllib.request,zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
ROOT=Path(os.environ['RUNNER_TEMP'])/'natural-prefilm'
CONTEXT=b'com.normiecore.hassynatural/private-prefilm/input/v1'
OUTPUT=b'com.normiecore.hassynatural/private-prefilm/output/v1'
CURRENT='0d405590144995297c5d4ab1faa9bb2beebccc66'
def key(shared,salt,context):return HKDF(algorithm=hashes.SHA256(),length=32,salt=salt,info=context).derive(shared)
def prepare():
    ROOT.mkdir(parents=True,exist_ok=True)
    e=json.loads(Path('.github/prefilm-input.enc.json').read_text())
    private=serialization.load_pem_private_key(os.environ['ASC_KEY_P8'].encode(),password=None)
    public=private.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
    if e['recipient_sha256']!=hashlib.sha256(public).hexdigest():raise ValueError('recipient')
    peer=serialization.load_der_public_key(base64.b64decode(e['ephemeral_public_key']))
    spec=json.loads(AESGCM(key(private.exchange(ec.ECDH(),peer),base64.b64decode(e['salt']),CONTEXT)).decrypt(base64.b64decode(e['nonce']),base64.b64decode(e['ciphertext']),CONTEXT))
    fixtures=Path('NaturalColor/ios/HassyNaturalTests/Fixtures');fixtures.mkdir(parents=True,exist_ok=True)
    def download(item):
        if item['id'] not in ['scene-a','scene-b']:raise ValueError('input name')
        dest=fixtures/(item['id']+'.dng')
        with urllib.request.urlopen(item['dng']['url'],timeout=120) as response,dest.open('wb') as out:shutil.copyfileobj(response,out)
        if hashlib.sha256(dest.read_bytes()).hexdigest()!=item['dng']['sha256']:raise ValueError('checksum')
    with ThreadPoolExecutor(max_workers=2) as executor:list(executor.map(download,spec['inputs']))
    (ROOT/'return-public.der').write_bytes(base64.b64decode(spec['return_public_key']))
    (fixtures/'prefilm-manifest.json').write_text(json.dumps([{'id':x['id'],'source_sha256':x['dng']['sha256']} for x in spec['inputs']]))
    Path('NaturalColor/ios/HassyNaturalTests/PrivatePrefilmFloatTests.swift').write_text(SWIFT)
    print('Two private RAW fixtures verified; only generic aliases are logged.')
def public_probe():
    url='https://www.dpreview.com/wp-content/uploads/sample_galleries/L-4239298554/6994506799.3fr'
    request=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0','Referer':'https://www.dpreview.com/products/hasselblad/slrs/hasselblad_x2dii100c/','Range':'bytes=0-63'})
    try:
        with urllib.request.urlopen(request,timeout=60) as r:
            head=r.read(64);status=r.status;kind=r.headers.get('Content-Type','')
    except urllib.error.HTTPError as error:
        print(json.dumps({'public_reference':'DPReview exact X2D II RAW','http_status':error.code,'probe_only':True,'private_native_capture_independent':True}),flush=True)
        raise
    if not (head.startswith(b'II*\x00') or head.startswith(b'MM\x00*')):
        print(json.dumps({'public_reference':'DPReview exact X2D II RAW','http_status':status,'content_type':kind,'tiff_container':False,'probe_only':True}),flush=True)
        raise ValueError('public RAW signature')
    print(json.dumps({'public_reference':'DPReview exact X2D II order 2 RAW','http_status':status,'content_type':kind,'bytes_read':len(head),'tiff_container':True,'headers':'Mozilla/5.0 + exact-product Referer'}))
def watch():
    path=Path(os.environ['RUNNER_TEMP'])/'prefilm-native.log';offset=0
    while True:
        if path.is_file():
            with path.open(errors='replace') as f:f.seek(offset);chunk=f.read();offset=f.tell()
            for line in chunk.splitlines():
                match=re.search(r'PREFILM_STAGE=([a-z0-9-]+)',line)
                if match:print('::notice title=Native float stage::'+match.group(1),flush=True)
        time.sleep(1)
def seal():
    log=(Path(os.environ['RUNNER_TEMP'])/'prefilm-native.log').read_text()
    paths=re.findall(r'PREFILM_DIRECTORY=(/[^\r\n]+)',log)
    if not paths:raise ValueError('output directory missing')
    directory=Path(paths[-1].strip());manifest=directory/'float-manifest.json'
    result=json.loads(manifest.read_text())
    for row in result['inputs']:
        p=directory/(row['id']+'.rgba32f')
        if p.stat().st_size!=row['width']*row['height']*4*4:raise ValueError('float length')
        row['sha256']=hashlib.sha256(p.read_bytes()).hexdigest();row['bytes']=p.stat().st_size
        control=directory/row['current_control']['file']
        row['current_control'].update(sha256=hashlib.sha256(control.read_bytes()).hexdigest(),bytes=control.stat().st_size)
    result['verified_app_source']=CURRENT
    result['host']={'xcode':subprocess.check_output(['xcodebuild','-version']).decode().strip(),'macos':subprocess.check_output(['sw_vers']).decode().strip(),'runner_image_version':os.environ.get('ImageVersion','unknown')}
    runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
    selected=next((rid,d) for rid,items in devices.items() for d in items if d['udid']==os.environ['SIM_UDID'])
    runtime=next(x for x in runtimes if x['identifier']==selected[0])
    result['selected_runtime']={k:runtime[k] for k in ['name','version','buildversion','identifier']};result['selected_runtime']['device']=selected[1]['name']
    manifest.write_text(json.dumps(result,indent=2))
    archive=ROOT/'floats.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=3) as z:
        for p in directory.iterdir():z.write(p,p.name)
    recipient=serialization.load_der_public_key((ROOT/'return-public.der').read_bytes());ephemeral=ec.generate_private_key(ec.SECP256R1());salt=os.urandom(32);nonce=os.urandom(12)
    cipher=AESGCM(key(ephemeral.exchange(ec.ECDH(),recipient),salt,OUTPUT)).encrypt(nonce,archive.read_bytes(),OUTPUT)
    chunk=20*1024*1024;parts=(len(cipher)+chunk-1)//chunk
    if parts>6:raise ValueError('output size')
    envelope={k:base64.b64encode(v).decode() for k,v in {'ephemeral_public_key':ephemeral.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo),'salt':salt,'nonce':nonce}.items()};envelope.update(parts=parts,ciphertext_bytes=len(cipher))
    (ROOT/'output-envelope.json').write_text(json.dumps(envelope))
    for i,start in enumerate(range(0,len(cipher),chunk)):(ROOT/f'output-{i:02d}.enc').write_bytes(cipher[start:start+chunk])
    archive.unlink();shutil.rmtree(directory)
    print('Authenticated float output sealed in '+str(parts)+' encrypted parts.')
SWIFT=r'''import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import HassyNatural

final class PrivatePrefilmFloatTests: XCTestCase {
    let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    func context() -> CIContext {CIContext(options:[.workingColorSpace:linear,.outputColorSpace:linear,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])}
    func bitmap(_ image:CIImage,width:Int,height:Int,using context:CIContext) -> [Float] {
        var data=[Float](repeating:0,count:width*height*4)
        data.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:linear) }
        return data
    }
    func finite(_ object:[String:Any]) -> [String:Any] {
        object.mapValues {value in if let n=value as? NSNumber,!n.doubleValue.isFinite {return NSNull()};return value}
    }
    func decoderReadback(_ decoder:CIRAWFilter) -> [String:Any] {
        var d:[String:Any]=["decoderVersion":String(describing:decoder.decoderVersion),"baselineExposure":decoder.baselineExposure,"shadowBias":decoder.shadowBias,"neutralTemperature":decoder.neutralTemperature,"neutralTint":decoder.neutralTint,"exposure":decoder.exposure,"boostAmount":decoder.boostAmount,"boostShadowAmount":decoder.boostShadowAmount,"localToneMapSupported":decoder.isLocalToneMapSupported,"gamutMappingEnabled":decoder.isGamutMappingEnabled]
        if decoder.isLocalToneMapSupported {d["localToneMapAmount"]=decoder.localToneMapAmount}
        return finite(d)
    }
    func metadata(_ url:URL) throws -> [String:Any] {
        try autoreleasepool {
            let decoder=try XCTUnwrap(CIRAWFilter(imageURL:url))
            let defaults=decoderReadback(decoder)
            decoder.boostAmount=0;decoder.boostShadowAmount=0
            if decoder.isLocalToneMapSupported {decoder.localToneMapAmount=0}
            decoder.isGamutMappingEnabled=false;decoder.exposure=0
            return ["defaults_before_app_overrides":defaults,"effective_app_settings":decoderReadback(decoder),"readback_method":"separate CIRAWFilter of the same original, with exact released PhotoEngine.load settings; float image itself comes from unmodified app PhotoEngine.load"]
        }
    }
    func rangeControl() throws -> [String:Any] {
        try autoreleasepool {
            let c=context();defer{c.clearCaches()}
            let expected:[Float]=[2,0.5,-0.25,1]
            let image=expected.withUnsafeBytes {CIImage(bitmapData:Data($0),bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:linear)}
            let actual=bitmap(image,width:1,height:1,using:c)
            for i in 0..<4 {XCTAssertEqual(actual[i],expected[i],accuracy:0.00001,"Float output must preserve extended and negative values")}
            let bottom=CIImage(color:try XCTUnwrap(CIColor(red:0.25,green:0.25,blue:0.25,alpha:1,colorSpace:linear))).cropped(to:CGRect(x:0,y:0,width:2,height:1))
            let top=CIImage(color:try XCTUnwrap(CIColor(red:0.75,green:0.75,blue:0.75,alpha:1,colorSpace:linear))).cropped(to:CGRect(x:0,y:1,width:2,height:1))
            let rows=bitmap(top.composited(over:bottom).cropped(to:CGRect(x:0,y:0,width:2,height:2)),width:2,height:2,using:c)
            let first=rows[0],last=rows[8]
            XCTAssertTrue(abs(first-0.25)<0.00001 || abs(first-0.75)<0.00001)
            XCTAssertEqual(first+last,1,accuracy:0.00001,"Both distinct coordinate rows must survive rendering")
            return ["expected_rgba":expected,"actual_rgba":actual,"coordinate_probe_first_row_red":first,"coordinate_probe_second_row_red":last,"buffer_row_order":abs(first-0.25)<0.00001 ? "bottom_to_top_in_CoreImage_coordinates":"top_to_bottom_in_CoreImage_coordinates"]
        }
    }
    func testExtendedRangeAndGeometryControl() throws {
        _ = try rangeControl()
    }
    func capture(_ item:[String:String],fixture:URL,directory:URL) async throws -> [String:Any] {
        let id=try XCTUnwrap(item["id"]),url=fixture.appendingPathComponent(id+".dng")
        let diagnostic=try metadata(url)
        let engine=PhotoEngine(),photo=try await engine.load(url:url)
        print("PREFILM_STAGE="+id+"-loaded")
        let scale=min(1,1536/max(photo.image.extent.width,photo.image.extent.height))
        let width=Int((photo.image.extent.width*scale).rounded()),height=Int((photo.image.extent.height*scale).rounded())
        let scaled=photo.image.transformed(by:.init(scaleX:scale,y:scale)).cropped(to:CGRect(x:0,y:0,width:width,height:height))
        // Already below the app preview cap: preview performs a scale of one.
        // Both the float sample and current-render control receive this exact CIImage.
        let small=LoadedPhoto(image:scaled,name:"private-control",isRaw:photo.isRaw)
        let control=try await engine.preview(photo:small,settings:.init())
        XCTAssertEqual(control.width,width);XCTAssertEqual(control.height,height)
        print("PREFILM_STAGE="+id+"-current-control-rendered")
        return try autoreleasepool {
            let c=context();defer{c.clearCaches()}
            let data=bitmap(scaled,width:width,height:height,using:c)
            var low=[Float](repeating:Float.infinity,count:4),high=[Float](repeating:-Float.infinity,count:4),sum=[Double](repeating:0,count:4),above=[Int](repeating:0,count:4),below=[Int](repeating:0,count:4),nonfinite=0
            for i in data.indices {let v=data[i],channel=i%4;if !v.isFinite {nonfinite+=1;continue};low[channel]=min(low[channel],v);high[channel]=max(high[channel],v);sum[channel]+=Double(v);if v>1 {above[channel]+=1};if v<0 {below[channel]+=1}}
            XCTAssertEqual(nonfinite,0)
            let file=directory.appendingPathComponent(id+".rgba32f")
            try data.withUnsafeBytes {try Data($0).write(to:file)}
            let controlURL=directory.appendingPathComponent(id+"-current-control.png")
            let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(controlURL as CFURL,UTType.png.identifier as CFString,1,nil))
            CGImageDestinationAddImage(destination,control,[kCGImagePropertyOrientation:1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            print("PREFILM_STAGE="+id+"-float-written")
            return ["id":id,"source_sha256":item["source_sha256"]!,"width":width,"height":height,"source_width":Int(photo.image.extent.width),"source_height":Int(photo.image.extent.height),"format":"little-endian IEEE754 Float32 RGBA interleaved; row stride width*16 bytes","color_space":"extendedLinearSRGB","stage":"released PhotoEngine.load output before exposure adjustment, recovered color/film kernel and all integer display/export conversion","exposureEV":0,"resampling":"same affine scale mechanism as released preview, long edge1536","range_min_rgba":low,"range_max_rgba":high,"mean_rgba":sum.map{$0/Double(width*height)},"count_above_one_rgba":above,"count_below_zero_rgba":below,"nonfinite_count":nonfinite,"decoder":diagnostic,"current_control":["file":id+"-current-control.png","format":"lossless PNG, 8-bit sRGB","width":width,"height":height,"method":"unmodified released PhotoEngine.preview with strength1 exposure0 nativeAspect applied to the exact same pre-scaled1536px CIImage as the float buffer; preview internal scaling equals one"]]
        }
    }
    func testCaptureTwoPrivatePrefilmFloats() async throws {
        executionTimeAllowance=600
        let fixture=try XCTUnwrap(Bundle(for:Self.self).resourceURL?.appendingPathComponent("Fixtures"))
        let inputs=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("prefilm-manifest.json"))) as? [[String:String]])
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("PrefilmFloat")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let control=try rangeControl();print("PREFILM_STAGE=extended-range-control-passed")
        var result=[[String:Any]]()
        for item in inputs {result.append(try await capture(item,fixture:fixture,directory:directory))}
        let systemVersion = await MainActor.run { UIDevice.current.systemVersion }
        let manifest:[String:Any]=["schema":"natural-prefilm-float-v1","rendered_app_source":"0d405590144995297c5d4ab1faa9bb2beebccc66","operating_system":ProcessInfo.processInfo.operatingSystemVersionString,"device_system_version":systemVersion,"rendering":"native iOS simulator; decoded original RAW using unmodified released app loader; no learned calibration or film transform","extended_range_and_geometry_control":control,"inputs":result]
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:directory.appendingPathComponent("float-manifest.json"))
        print("PREFILM_DIRECTORY="+directory.path)
    }
}
'''
if __name__=='__main__':
    try:
        {'prepare':prepare,'probe':public_probe,'watch':watch,'seal':seal}[sys.argv[1]]()
    except Exception:
        raise SystemExit('Private float operation failed. No private references or photographs printed.') from None
