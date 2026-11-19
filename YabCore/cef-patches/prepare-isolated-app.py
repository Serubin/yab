#!/usr/bin/env python3
"""Preparation-only once-copy/sign/link proof. Never launches/builds an app."""
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
import sys

# Explicit local module loading avoids ambient-path/self-import ambiguity.
_policy_spec=importlib.util.spec_from_file_location('yab_candidate_parent_policy',Path(__file__).with_name('candidate_parent_policy.py'))
POLICY=importlib.util.module_from_spec(_policy_spec);_policy_spec.loader.exec_module(POLICY)

TEAM = '25UG4QYN9F'
PREFIX = 'dev.serafim.yab.probe.gui.'
MAGIC = {bytes.fromhex(x) for x in ('feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca')}


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): digest.update(block)
    return digest.hexdigest()


def tree(app):
    root = Path(app).resolve(); result = {}
    for path in sorted(root.rglob('*')):
        rel = str(path.relative_to(root)); mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            if not path.resolve().is_relative_to(root): raise ValueError('Bundle symlink escapes artifact: '+rel)
            result[rel] = [mode,'link',os.readlink(path)]
        elif path.is_dir(): result[rel] = [mode,'directory']
        elif path.is_file(): result[rel] = [mode,'file',sha(path)]
        else: raise ValueError('Unsupported app member: '+rel)
    if not result: raise ValueError('Empty app')
    return result


def task_info(info, task, bundle_id):
    if not task or task in ('.','..') or any(ord(c)<32 or c in '/\\' for c in task): raise ValueError('Invalid task name')
    if str(info.get('CFBundleIdentifier','')).startswith(PREFIX): raise ValueError('Input is already an isolated candidate; refusing to re-sign it')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable,str) or not executable or executable in ('.','..') or any(c in executable for c in '/\\\0'):
        raise ValueError('Unsafe original executable name')
    if not re.fullmatch(re.escape(PREFIX)+r'[0-9a-f]{16}',bundle_id) or bundle_id == info.get('CFBundleIdentifier'):
        raise ValueError('Requires a fresh dedicated short probe identifier')
    return dict(info,CFBundleIdentifier=bundle_id,CFBundleName=task,CFBundleDisplayName=task)


def identity(metadata):
    authorities = [line[len('Authority='):] for line in metadata.splitlines() if line.startswith('Authority=')]
    if not authorities or not authorities[0].startswith('Developer ID Application: '): raise ValueError('Developer ID input required')
    if re.findall(r'^TeamIdentifier=(.*)$',metadata,re.M) != [TEAM]: raise ValueError('Unexpected signing team')
    if not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\([^\n]*\bruntime\b',metadata,re.M|re.I): raise ValueError('Input lacks hardened runtime')
    return authorities[0]


def signature_delta(before, after, executable):
    allowed = {'Contents/Info.plist','Contents/MacOS/'+executable}
    for path in set(before)|set(after):
        if path in allowed or path=='Contents/_CodeSignature' or path.startswith('Contents/_CodeSignature/'): continue
        if before.get(path) != after.get(path): raise ValueError('Signing changed nested/native/resource bytes: '+path)
    for path in allowed:
        if path not in before or path not in after or before[path][:2] != after[path][:2]: raise ValueError('Signing changed main file kind/mode')


def nested_ids(app):
    result = {}
    for path in sorted(Path(app).rglob('Info.plist')):
        rel = str(path.relative_to(app))
        if rel == 'Contents/Info.plist': continue
        info = plistlib.loads(path.read_bytes())
        if 'CFBundleIdentifier' in info: result[rel] = info['CFBundleIdentifier']
    return result


def linked_command(verifier, original, input_app, app, out, input_receipt):
    if original.get('signingTeam') != TEAM or Path(original['app']).resolve() != Path(input_app).resolve():
        raise ValueError('Input linked proof belongs to another app/team')
    for key in ('sdk','coreApp','sdkFrameworkSha256','frameworkUuid','helperUuid'):
        if not isinstance(original.get(key),str) or not original[key]: raise ValueError('Incomplete input linked provenance: '+key)
    if Path(out).resolve() == Path(input_receipt).resolve() or Path(app).resolve() == Path(input_app).resolve(): raise ValueError('Cannot reuse old linked proof/app')
    return [sys.executable,str(verifier),'--sdk',original['sdk'],'--app',str(app),'--core-app',original['coreApp'],'--out',str(out)]


def sign_command(signer, entitlements, app, keychain=None):
    command = ['codesign','--force','--sign',signer,'--options','runtime','--timestamp']
    if keychain: command += ['--keychain',keychain]
    if entitlements: command += ['--entitlements',str(entitlements)]
    return command+[str(app)]  # Deliberately NO --deep: nested JIT signatures stay exact.


def run(args):
    return subprocess.run([str(x) for x in args],check=True,capture_output=True,timeout=180)


def entitlements(path):
    data = run(['codesign','-d','--entitlements',':-',path]).stdout
    value = plistlib.loads(data) if data.strip() else {}
    if not isinstance(value,dict): raise ValueError('Invalid signing entitlements')
    return value,data


def description(path):
    run(['codesign','--verify','--strict',path])
    result = run(['codesign','-dvv',path]); metadata=(result.stdout+result.stderr).decode()
    signer = identity(metadata); ent,_ = entitlements(path)
    return {'metadata':metadata,'entitlements':ent,'signer':signer}


def macho_uuids(path):
    text = run(['dwarfdump','--uuid',path]).stdout.decode()
    values = re.findall(r'^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)',text,re.M)
    if not values or len({arch for _,arch in values}) != len(values): raise ValueError('Missing/ambiguous Mach-O UUID')
    return {arch:identifier.upper() for identifier,arch in values}


def prepare(args):
    source=args.input.resolve(); target=args.output.resolve(); receipt=args.receipt.resolve(); linked=args.linked_output.resolve()
    if source.suffix != '.app' or not source.is_dir() or source.is_symlink(): raise ValueError('Input must be original prepared app directory')
    if target.exists() or receipt.exists() or linked.exists(): raise ValueError('Preparation outputs already exist; refusing repeat/sign again')
    if target.suffix != '.app' or target.name != args.task+'.app' or target.is_relative_to(source) or source.is_relative_to(target): raise ValueError('Unsafe/misnamed output location')
    if receipt==linked or receipt==args.input_linked.resolve() or linked==args.input_linked.resolve(): raise ValueError('Receipt paths must be fresh and distinct')
    if any(path.is_relative_to(bundle) for path in (receipt,linked) for bundle in (source,target)): raise ValueError('Receipts must live outside signed app bundles')
    plan=POLICY.load_plan(args.policy_plan); bid=POLICY.valid_id(args.bundle_id)
    if plan.bundle_id!=bid: raise ValueError('Final ID differs from precompile plan')
    policy_header=Path(args.policy_header) if args.policy_header else None
    POLICY.verify_header(plan,policy_header)
    plan_sha=sha(args.policy_plan)
    receipt.parent.mkdir(parents=True,exist_ok=True)
    input_linked_sha=sha(args.input_linked)
    original=json.loads(args.input_linked.read_text()); verifier=Path(__file__).with_name('verify-linked-sdk.py').resolve()
    verifier_sha=sha(verifier)
    command=linked_command(verifier,original,source,target,linked,args.input_linked)
    info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
    rewritten=task_info(info,args.task,bid)
    executable=info['CFBundleExecutable']; main=source/'Contents/MacOS'/executable
    if not main.is_file() or main.is_symlink() or not (source/'Contents/MacOS/PaneCore').is_file(): raise ValueError('Missing ordinary executable/native helper')
    run(['codesign','--verify','--deep','--strict',source])
    outer=description(source); input_ent,raw_ent=entitlements(source)
    if plan.requirement is not None:
        signer=POLICY.signer_evidence(source,plan.leaf_sha1)
        if signer['leafSHA256']!=plan.leaf_sha256 or signer['team']!=plan.team or signer['authority']!=plan.authority:
            raise ValueError('Actual source signer differs from precompiled policy')
    before=tree(source); ids=nested_ids(source); main_uuid=macho_uuids(main)
    # Explicitly retain every nested Mach-O entitlement, including GPU/renderer
    # roles. Exact nested byte projection below additionally pins their signatures.
    nested={}
    for rel,row in before.items():
        path=source/rel
        if row[1]!='file' or path==main: continue
        with path.open('rb') as stream: magic=stream.read(4)
        if magic in MAGIC: nested[rel]=description(path)
    if not any(' (GPU).app/' in name for name in nested) or not any(' (Renderer).app/' in name for name in nested): raise ValueError('Missing signed CEF roles')
    target.parent.mkdir(parents=True,exist_ok=True)
    if not target.parent.is_dir(): raise ValueError('Missing output directory')
    shutil.copytree(source,target,symlinks=True)  # ONE preparation copy, never a per-row launch clone.
    if tree(target)!=before or tree(source)!=before: raise ValueError('Input/copy changed during preparation')
    if os.path.samefile(main,target/'Contents/MacOS'/executable): raise ValueError('Main executable unexpectedly hardlinked')
    run(['codesign','--verify','--deep','--strict',target])  # Verify actual copy BEFORE altering/signing it.
    (target/'Contents/Info.plist').write_bytes(plistlib.dumps(rewritten))
    entitlement_file=receipt.with_name(receipt.name+'.parent-entitlements.plist')
    if entitlement_file.exists(): raise ValueError('Entitlement output already exists')
    if raw_ent.strip(): entitlement_file.write_bytes(raw_ent)
    run(sign_command(plan.leaf_sha1 if plan.requirement is not None else outer['signer'],entitlement_file if raw_ent.strip() else None,target,os.environ.get('YAB_SIGN_KEYCHAIN')))
    run(['codesign','--verify','--deep','--strict',target])
    signed=description(target)
    if plan.requirement is not None:
        # Same precompiled requirement against the SOLE actual final signed copy.
        run(['/usr/bin/codesign','--verify','--deep','--strict','--all-architectures','-R',plan.requirement,target])
        signer=POLICY.signer_evidence(target,plan.leaf_sha1)
        if signer['leafSHA256']!=plan.leaf_sha256: raise ValueError('Final actual certificate differs')
    after=tree(target); signature_delta(before,after,executable)
    if tree(source)!=before: raise ValueError('Preparation mutated source app')
    if signed['signer']!=outer['signer'] or signed['entitlements']!=input_ent: raise ValueError('Outer signing authority/entitlements changed')
    if nested_ids(target)!=ids or plistlib.loads((target/'Contents/Info.plist').read_bytes())!=rewritten: raise ValueError('Bundle/native identifiers changed unexpectedly')
    if macho_uuids(target/'Contents/MacOS'/executable)!=main_uuid: raise ValueError('Main Mach-O payload/architectures changed')
    # Fresh actual verifier invocation AFTER signing against the SOLE final copy.
    linked.parent.mkdir(parents=True,exist_ok=True);run(command)
    refreshed=json.loads(linked.read_text())
    if sha(verifier)!=verifier_sha or sha(args.input_linked)!=input_linked_sha: raise ValueError('Verifier/input proof changed during preparation')
    if tree(target)!=after or tree(source)!=before: raise ValueError('App changed during fresh linked proof')
    if sha(args.policy_plan)!=plan_sha: raise ValueError('Precompile plan changed during preparation')
    POLICY.verify_header(plan,policy_header)
    if Path(refreshed['app']).resolve()!=target: raise ValueError('Fresh linked proof targets wrong app')
    for key in ('sdkFrameworkSha256','frameworkUuid','helperUuid','signingTeam'):
        if refreshed.get(key)!=original.get(key): raise ValueError('SDK/helper link changed: '+key)
    result={'schema':1,'classification':'ISOLATED_SIGNED_PREPARATION_NOT_RUNTIME_ACCEPTANCE','inputApp':str(source),'app':str(target),
      'inputBundleIdentifier':info['CFBundleIdentifier'],'bundleIdentifier':bid,'task':args.task,'CFBundleExecutable':executable,
      'inputMainSHA256':before['Contents/MacOS/'+executable][2],'signedMainSHA256':after['Contents/MacOS/'+executable][2],
      'mainMachOUUIDs':main_uuid,'inputLinkedReceipt':str(args.input_linked.resolve()),'inputLinkedReceiptSHA256':input_linked_sha,
      'linkedReceipt':str(linked),'linkedReceiptSHA256':sha(linked),'verifierSHA256':verifier_sha,'preparerSHA256':sha(Path(__file__)),
      'inputTreeSHA256':hashlib.sha256(json.dumps(before,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
      'outputTreeSHA256':hashlib.sha256(json.dumps(after,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
      'inputTree':before,'outputTree':after,'nestedBundleIdentifiers':ids,'inputNestedSigning':nested,'outputParentSigning':signed,
      'parentEntitlements':input_ent,'signingTeam':TEAM,'developerIDAuthority':outer['signer'],
      'nestedBytesUnchanged':True,'sourceAppUnchanged':True,'copyCount':1,'outerSignCount':1,'nativeIDsUnchanged':True,
      'runtimeAccepted':False,'preparedOnly':True,'linkedScope':refreshed.get('scope'),
      'precompilePlan':str(args.policy_plan.resolve()),'precompilePlanSHA256':plan_sha,
      'compiledPolicyHeaderSHA256':plan.header_sha256,'compiledParentBundleIdentifier':plan.bundle_id,
      'parentRequirementVerified':plan.requirement is not None,'acceptedVersion':0}
    receipt.parent.mkdir(parents=True,exist_ok=True);receipt.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('input','output','input-linked','linked-output','receipt'): parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--task',required=True);parser.add_argument('--bundle-id',required=True);parser.add_argument('--policy-plan',type=Path,required=True);parser.add_argument('--policy-header');args=parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER')!='1': parser.error('Run preparation through the authorized farm; never on a probe row')
    result=prepare(args)
    print(json.dumps({k:result[k] for k in ('classification','app','bundleIdentifier','linkedReceipt','runtimeAccepted')},ensure_ascii=False))
if __name__=='__main__':main()
