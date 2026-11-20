"""Give the CEF browser process a complete, independently identified app bundle."""
import plistlib
import shutil
from pathlib import Path


PAYLOADS = ['Chromium Embedded Framework.framework'] + [
    'PaneCore Helper' + suffix + '.app'
    for suffix in ('', ' (GPU)', ' (Renderer)', ' (Plugin)', ' (Alerts)')]


def relocate_payloads(app, bundle):
    """CEF's sandboxed children need real paths under their browser bundle."""
    frameworks = Path(app) / 'Contents/Frameworks'
    nested = Path(bundle) / 'Contents/Frameworks'
    for name in PAYLOADS:
        source = frameworks / name
        if source.is_symlink() or not source.is_dir():
            raise RuntimeError('Fresh CEF payload required: ' + str(source))
    if nested.is_symlink():
        nested.unlink()
    nested.mkdir(exist_ok=True)
    for name in PAYLOADS:
        source = frameworks / name
        target = nested / name
        if target.exists():
            raise RuntimeError('CEF payload already exists: ' + str(target))
        shutil.move(source, target)
        source.symlink_to('PaneCore.app/Contents/Frameworks/' + name, target_is_directory=True)


def package(app):
    app = Path(app)
    outer = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    legacy = app / 'Contents/MacOS/PaneCore'
    bundle = app / 'Contents/Frameworks/PaneCore.app'
    binary = bundle / 'Contents/MacOS/PaneCore'
    # Repeated embedding owns only this bundle and its legacy entry point.
    if legacy.is_symlink() or not legacy.is_file():
        raise RuntimeError('A freshly copied regular YabCore executable is required')
    if bundle.is_symlink():
        raise RuntimeError('The owned YabCore bundle must not be a symlink')
    for name in PAYLOADS:
        source = app / 'Contents/Frameworks' / name
        if source.is_symlink() or not source.is_dir():
            raise RuntimeError('Fresh CEF payload required: ' + str(source))
    if bundle.exists():
        shutil.rmtree(bundle)
    binary.parent.mkdir(parents=True)
    shutil.move(legacy, binary)
    info = dict(CFBundleExecutable='PaneCore', CFBundleName='PaneCore',
                CFBundleDisplayName='PaneCore',
                CFBundleIdentifier=outer['CFBundleIdentifier'] + '.core',
                CFBundlePackageType='APPL', CFBundleInfoDictionaryVersion='6.0',
                CFBundleVersion=outer['CFBundleVersion'],
                CFBundleShortVersionString=outer['CFBundleShortVersionString'],
                LSMinimumSystemVersion=outer.get('LSMinimumSystemVersion', '13.0'),
                LSUIElement=True, NSPrincipalClass='NSApplication',
                NSSupportsAutomaticTermination=False, NSSupportsSuddenTermination=False,
                NSSupportsAutomaticGraphicsSwitching=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Keep the entire native browser tree together. Upward directory links
    # make the Chromium child sandbox reject the framework's resolved path.
    relocate_payloads(app, bundle)
    legacy.symlink_to('../Frameworks/PaneCore.app/Contents/MacOS/PaneCore')
    return bundle

if __name__ == '__main__':
    import sys
    print(package(sys.argv[1]))
