from pathlib import Path
import functools, http.server, os, plistlib, shutil, subprocess, threading, time, sys
root=Path(sys.argv[1])
repository=Path(sys.argv[2])
fixtures=repository/'Tests/UpdaterSmoke'
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(root)))
threading.Thread(target=server.serve_forever,daemon=True).start()
port=server.server_address[1]
environment=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(repository/'.build/module-cache'))
subprocess.run(['swift',str(fixtures/'Sign.swift'),'key',str(root)],check=True,env=environment)
public_key=(root/'public-key').read_text()
identifier='local.theatre.updater-smoke.'+str(int(time.time()))
for version,folder in [('1','installed'),('2','new')]:
    app=root/folder/'UpdaterProbe.app'
    (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    (app/'Contents/Frameworks').mkdir(exist_ok=True)
    shutil.copy2(root/'Probe',app/'Contents/MacOS/Probe')
    framework=repository/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    subprocess.run(['ditto',str(framework),str(app/'Contents/Frameworks/Sparkle.framework')],check=True)
    info=dict(CFBundleIdentifier=identifier,CFBundleExecutable='Probe',CFBundleName='UpdaterProbe',CFBundleVersion=version,CFBundleShortVersionString=version+'.0',CFBundlePackageType='APPL',TheatreSmokeRoot=str(root),LSMinimumSystemVersion='13.0',SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml',SUPublicEDKey=public_key,SUEnableAutomaticChecks=False,SUAllowsAutomaticUpdates=False,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,NSAppTransportSecurity={'NSAllowsArbitraryLoads':True})
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['bash','Scripts/verify-app.sh',str(app)],check=True)
# Reproduce the packaging regression: the framework exists, but its search path is absent.
broken=root/'broken/UpdaterProbe.app'
subprocess.run(['ditto',str(root/'installed/UpdaterProbe.app'),str(broken)],check=True)
subprocess.run(['install_name_tool','-delete_rpath','@executable_path/../Frameworks',str(broken/'Contents/MacOS/Probe')],check=True,stderr=subprocess.DEVNULL)
subprocess.run(['codesign','--force','--sign','-',str(broken)],check=True,stderr=subprocess.DEVNULL)
result=subprocess.run(['bash','Scripts/verify-app.sh',str(broken)],capture_output=True,text=True)
assert result.returncode!=0 and 'Missing app Frameworks runtime search path' in result.stderr
print('PASS: Packaging rejects an app with the missing-framework-search-path crash.')
subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(root/'new/UpdaterProbe.app'),str(root/'update.zip')],check=True)
subprocess.run(['swift',str(fixtures/'Sign.swift'),'sign',str(root),str(port)],check=True,env=environment)
subprocess.run(['swift','Scripts/verify-update.swift',str(root/'installed/UpdaterProbe.app/Contents/Info.plist'),str(root/'appcast.xml'),str(root/'update.zip')],check=True,env=environment)
with (root/'run.log').open('w') as log:
    process=subprocess.Popen([str(root/'installed/UpdaterProbe.app/Contents/MacOS/Probe')],stdout=log,stderr=log,env=environment)
    deadline=time.time()+75
    while time.time()<deadline and not (root/'success').exists():
        if process.poll() is not None and process.returncode!=0: break
        time.sleep(.2)
    if (root/'success').exists():
        info=plistlib.loads((root/'installed/UpdaterProbe.app/Contents/Info.plist').read_bytes())
        assert info['CFBundleVersion']=='2'
        assert (root/'prepared').exists()
        print('PASS: Real Sparkle detected version 2, verified and downloaded it, awaited AppUpdater preparation, installed it and relaunched version 2.')
    else:
        print('FAIL: Updater smoke test did not complete. Exit:',process.poll())
        print((root/'run.log').read_text()[-7000:])
        if process.poll() is None: process.terminate()
        raise SystemExit(1)
server.shutdown()
(root/'test-only-key').unlink(missing_ok=True)
