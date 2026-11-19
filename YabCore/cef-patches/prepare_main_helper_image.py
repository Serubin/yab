#!/usr/bin/env python3
"""Preparation-only signed helper→compiled main diagnostic pin. No app launch.

Production version/allowlist never enabled. Tests use original ad-hoc API apps;
this creates ONE independent plain helper copy before main Swift compilation.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
SWIFT='YabCore/Client/Sources/YabCoreClient/CompiledOriginalHelperImagePolicy.swift'
DEFAULT='''// Default source. A qualified PREPARATION may rewrite only this tracked file in
// its owned farm snapshot before main compilation; exact source SHA is sealed.
// These are diagnostic pins ONLY. Production accepted version/set stay0/empty.
enum CompiledOriginalHelperImagePolicy {
    static let version = 0
    static let candidateIdentifier = ""
    static let helperIdentifier = ""
    static let helperCodeDirectories: Set<String> = []
    static let helperLeafSHA256 = ""
}
'''.encode()
KIND='SIGNED_HELPER_MAIN_DIAGNOSTIC_INPUT_NOT_PRODUCTION_AUTHORITY'

def module():
    p=Path(__file__).with_name('candidate_parent_policy.py');s=importlib.util.spec_from_file_location('main_parent_input',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
POLICY=module()
def sha(path):return POLICY.digest(Path(path).read_bytes())
def run(argv):return subprocess.run([str(v) for v in argv],check=True,capture_output=True,timeout=180)
def uuids(path):
    text=run(['/usr/bin/dwarfdump','--uuid',path]).stdout.decode()
    rows=re.findall(r'^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)',text,re.M)
    if len(rows)!=1 or rows[0][1]!='arm64':raise ValueError('Exact arm64-only helper UUID required')
    return {'arm64':rows[0][0].upper()}

def image(path,selected_leaf=None):
    path=Path(path)
    if path.is_symlink() or not path.is_file() or not 1<=path.stat().st_size<=256*1024*1024:raise ValueError('Exact bounded native helper file required')
    before=sha(path)
    run(['/usr/bin/codesign','--verify','--strict','--all-architectures',path])
    metadata=run(['/usr/bin/codesign','-dvv','--arch','arm64',path]);text=(metadata.stdout+metadata.stderr).decode('utf8','strict')
    ids=re.findall(r'^Identifier=(.+)$',text,re.M);codes=re.findall(r'^CDHash=([0-9a-fA-F]+)$',text,re.M)
    if len(ids)!=1 or not 1<=len(ids[0])<=256 or len(codes)!=1 or not 32<=len(codes[0])<=128 or len(codes[0])%2:raise ValueError('Actual native helper CodeDirectory/identifier missing')
    result={'path':str(path.resolve()),'sha256':before,'identifier':ids[0],'codeDirectory':codes[0].lower(),'uuids':uuids(path),'metadata':text}
    ent=run(['/usr/bin/codesign','-d','--entitlements',':-',path]).stdout
    result['entitlements']=plistlib.loads(ent) if ent.strip() else {}
    if selected_leaf is not None:
        if not re.fullmatch(r'[0-9a-f]{40}',selected_leaf):raise ValueError('Exact selected signing certificate required')
        with tempfile.TemporaryDirectory(prefix='yab-main-helper-certificate-') as tmp:
            prefix=Path(tmp)/'certificate';run(['/usr/bin/codesign','-d','--extract-certificates',prefix,path])
            leaf=Path(str(prefix)+'0').read_bytes()
            if not 1<=len(leaf)<=65536 or hashlib.sha1(leaf).hexdigest()!=selected_leaf:raise ValueError('Actual helper certificate differs from selected signer')
            result['leafSHA256']=POLICY.digest(leaf)
        team=re.findall(r'^TeamIdentifier=([A-Z0-9]{10})$',text,re.M);authorities=re.findall(r'^Authority=(.+)$',text,re.M)
        if len(team)!=1 or not authorities or not authorities[0].startswith('Developer ID Application: ') or not authorities[0].endswith(' ('+team[0]+')'):raise ValueError('Actual DeveloperID helper chain missing')
        if not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\([^\n]*\bruntime\b',text,re.M|re.I):raise ValueError('Actual helper hardened runtime missing')
        run(['/usr/bin/codesign','--verify','--strict','--all-architectures','-R','anchor apple generic and certificate leaf = H"'+selected_leaf+'"',path])
        result['team']=team[0];result['authority']=authorities[0]
    if sha(path)!=before:raise ValueError('Helper changed during actual native inspection')
    return result

def source_bytes(plan,signed):
    if plan.requirement is None:raise ValueError('No issued parent build input')
    if any(not isinstance(v,str) or not v or any(ord(c)<32 or ord(c)>126 for c in v) for v in (plan.bundle_id,signed['identifier'],signed['codeDirectory'],signed['leafSHA256'])): raise ValueError('Bounded ASCII native policy literals required')
    literal=lambda v:json.dumps(v,ensure_ascii=True)
    return ('// Generated trusted BUILD input, diagnostic only; production remains0/empty.\n'
      'enum CompiledOriginalHelperImagePolicy {\n'
      '    static let version = 1\n'
      '    static let candidateIdentifier = '+literal(plan.bundle_id)+'\n'
      '    static let helperIdentifier = '+literal(signed['identifier'])+'\n'
      '    static let helperCodeDirectories: Set<String> = ['+literal(signed['codeDirectory'])+']\n'
      '    static let helperLeafSHA256 = '+literal(signed['leafSHA256'])+'\n}\n').encode()

def expected_parent(plan_path,header):
    plan=POLICY.load_plan(plan_path);POLICY.verify_header(plan,header)
    if plan.requirement is None:raise ValueError('Actual signed parent policy preparation input required')
    return plan

def signature_command(plan,identifier,entitlements,target,keychain=None):
    args=['/usr/bin/codesign','--force','--options','runtime','--sign',plan.leaf_sha1,'--identifier',identifier,'--timestamp','--entitlements',str(entitlements)]
    if keychain:args+=['--keychain',keychain]
    return args+[str(target)]

def prepare(args):
    if os.environ.get('YAB_FARM_WORKER')!='1':raise ValueError('Signing/preparation only through authorized farm')
    source_root=args.source_root.resolve()
    if source_root!=ROOT:raise ValueError('Only the owned farm source snapshot may receive compiled input')
    swift=source_root/SWIFT
    if swift.is_symlink() or swift.read_bytes()!=DEFAULT:raise ValueError('Tracked diagnostic Swift input already issued/changed; refuse overwrite')
    run(['git','-C',source_root,'ls-files','--error-unmatch','--',SWIFT]) # Tracked path survives exclude-standard, not an ignored generated file.
    plan=expected_parent(args.parent_plan,args.policy_header)
    original=args.helper.resolve();target=args.output.resolve();receipt=args.receipt.resolve();sidecar=receipt.with_name(receipt.name+'.compiled.swift')
    if target.exists() or receipt.exists() or sidecar.exists() or args.helper.is_symlink():raise ValueError('Fresh independent helper/receipt only; original ad-hoc app stays immutable')
    if target.name!='PaneCore' or original==target:raise ValueError('Fixed native filename, independent output required')
    entitlements=source_root/'scripts/cef/helper-entitlements.plist';ent_sha=sha(entitlements);expected_ent=plistlib.loads(entitlements.read_bytes())
    old=image(original);target.parent.mkdir(parents=True,exist_ok=True)
    POLICY.fresh_write(target,original.read_bytes());os.chmod(target,stat.S_IMODE(original.stat().st_mode))
    if sha(target)!=old['sha256'] or sha(original)!=old['sha256']:raise ValueError('Original/helper preparation copy changed')
    run(signature_command(plan,old['identifier'],entitlements,target,os.environ.get('YAB_SIGN_KEYCHAIN')))
    signed=image(target,plan.leaf_sha1)
    if signed['identifier']!=old['identifier'] or signed['uuids']!=old['uuids'] or signed['leafSHA256']!=plan.leaf_sha256 or signed['team']!=plan.team or signed['entitlements']!=expected_ent:raise ValueError('Actual signed native IDs/UUID/signer/entitlements differ')
    if sha(original)!=old['sha256'] or sha(entitlements)!=ent_sha:raise ValueError('Preparation mutated original API app/input')
    compiled=source_bytes(plan,signed);POLICY.fresh_write(sidecar,compiled)
    # Atomic replacement of EXACT known default tracked source in this owned job.
    temporary=swift.with_name(swift.name+'.candidate-input')
    POLICY.fresh_write(temporary,compiled)
    if swift.read_bytes()!=DEFAULT:raise ValueError('Parallel source change before compiled-input publication')
    os.replace(temporary,swift)
    binding={'schema':1,'classification':KIND,'acceptedVersion':0,'productionEnabled':False,
      'parentPlanPath':str(args.parent_plan.resolve()),'parentPlanSHA256':sha(args.parent_plan),
      'policyHeaderPath':str(args.policy_header.resolve()),'policyHeaderSHA256':sha(args.policy_header),
      'candidateIdentifier':plan.bundle_id,'signerLeafSHA1':plan.leaf_sha1,'original':old,'signed':signed,
      'entitlementsSourceSHA256':ent_sha,'swiftSourcePath':SWIFT,'swiftSourceBeforeSHA256':POLICY.digest(DEFAULT),
      'swiftSourceSHA256':POLICY.digest(compiled),'swiftSidecar':str(sidecar),'swiftSidecarSHA256':sha(sidecar),
      'preparerSHA256':sha(Path(__file__)),'parentInputModuleSHA256':sha(Path(__file__).with_name('candidate_parent_policy.py')),
      'preparedOnly':True,'runtimeAccepted':False}
    POLICY.fresh_write(receipt,(json.dumps(binding,indent=2)+'\n').encode());return binding

def binding(args):
    row=json.loads(args.receipt.read_text())
    if type(row.get('schema')) is not int or row.get('schema')!=1 or row.get('classification')!=KIND or type(row.get('acceptedVersion')) is not int or row.get('acceptedVersion')!=0 or row.get('productionEnabled') is not False or row.get('runtimeAccepted') is not False:raise ValueError('Not an unaccepted signed helper build binding')
    plan_path=Path(row['parentPlanPath']);header=Path(row['policyHeaderPath']);plan=expected_parent(plan_path,header)
    if sha(plan_path)!=row['parentPlanSHA256'] or sha(header)!=row['policyHeaderSHA256'] or plan.bundle_id!=row['candidateIdentifier'] or plan.leaf_sha1!=row['signerLeafSHA1']:raise ValueError('Original compiled parent input changed')
    if sha(Path(__file__))!=row['preparerSHA256'] or sha(Path(__file__).with_name('candidate_parent_policy.py'))!=row['parentInputModuleSHA256']:raise ValueError('Input verifier changed')
    if row['swiftSourcePath']!=SWIFT:raise ValueError('Foreign source path')
    compiled=source_bytes(plan,row['signed'])
    if POLICY.digest(compiled)!=row['swiftSourceSHA256'] or (ROOT/SWIFT).read_bytes()!=compiled or Path(row['swiftSidecar']).read_bytes()!=compiled or sha(row['swiftSidecar'])!=row['swiftSidecarSHA256']:raise ValueError('Actual compiled Swift input/sidecar changed')
    if sha(ROOT/'scripts/cef/helper-entitlements.plist')!=row['entitlementsSourceSHA256']:raise ValueError('Native entitlements input changed')
    observed=image(Path(row['signed']['path']),plan.leaf_sha1)
    for key in ('sha256','identifier','codeDirectory','uuids','leafSHA256','team','entitlements'):
        if observed[key]!=row['signed'][key]:raise ValueError('Actual prepared signed helper changed: '+key)
    if observed['leafSHA256']!=plan.leaf_sha256:raise ValueError('Native helper does not match actual parent signer')
    return row,plan

def verify(args):
    row,plan=binding(args)
    if args.signing_identity is not None and args.signing_identity.lower()!=plan.leaf_sha1: raise ValueError('Embed signer is not the exact selected certificate')
    if args.original_helper:
        if args.original_helper.resolve()!=Path(row['original']['path']): raise ValueError('Original experimental helper path changed')
        old=image(args.original_helper)
        for key in ('sha256','identifier','codeDirectory','uuids'):
            if old[key]!=row['original'][key]:raise ValueError('Original experimental ad-hoc API test artifact changed')
    if args.embedded:
        target=args.embedded
        if target.name!='PaneCore' or target.parent.name!='MacOS' or target.parent.parent.name!='Contents' or target.parent.parent.parent.suffix!='.app': raise ValueError('Exact nested parent helper path required')
        final=image(args.embedded,plan.leaf_sha1)
        for key in ('sha256','identifier','codeDirectory','uuids','leafSHA256','team','entitlements'):
            if final[key]!=row['signed'][key]:raise ValueError('Actual embedded/final signed helper changed: '+key)
        if args.out:
            POLICY.fresh_write(args.out,(json.dumps({'schema':1,'classification':'ACTUAL_EMBEDDED_HELPER_IMAGE_NOT_RUNTIME_AUTHORITY','bindingSHA256':sha(args.receipt),'embedded':final,'acceptedVersion':0,'runtimeAccepted':False},indent=2)+'\n').encode())
    return row

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('mode',choices=['prepare','verify']);p.add_argument('--receipt',type=Path,required=True)
    p.add_argument('--helper',type=Path);p.add_argument('--output',type=Path);p.add_argument('--source-root',type=Path);p.add_argument('--parent-plan',type=Path);p.add_argument('--policy-header',type=Path)
    p.add_argument('--signing-identity');p.add_argument('--original-helper',type=Path);p.add_argument('--embedded',type=Path);p.add_argument('--out',type=Path);a=p.parse_args()
    if a.mode=='prepare':
        if not all((a.helper,a.output,a.source_root,a.parent_plan,a.policy_header)):p.error('prepare requires exact actual experimental helper/parent input/output source paths')
        result=prepare(a)
    else:result=verify(a)
    print(json.dumps({'classification':KIND,'helperCodeDirectory':result['signed']['codeDirectory'],'compiledSwiftSHA256':result['swiftSourceSHA256'],'acceptedVersion':0,'runtimeAccepted':False}))
if __name__=='__main__':main()
