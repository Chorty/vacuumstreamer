#!/usr/bin/env python3
"""Exercise the real shell installer with real PEM validation and fake robot IO."""
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SHELL = sys.argv.pop(1) if len(sys.argv) > 1 else "sh"
REPO = Path(__file__).resolve().parents[1]
OPENSSL = shutil.which("openssl")

TOOLS = r'''#!/usr/bin/env python3
import fcntl,os,pathlib,subprocess,sys
t=pathlib.Path(os.environ['CERT_TEST'])
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
if name=='flock':
    assert a==['-n','9']
    try:fcntl.flock(9,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:sys.exit(1)
elif name=='timeout':
    assert a[:2]==['-s','KILL']
    try:sys.exit(subprocess.run(a[3:],timeout=float(a[2])*float(os.environ.get('TIME_SCALE','1'))).returncode)
    except subprocess.TimeoutExpired:sys.exit(124)
elif name=='mv':
    if a[0]=='-fT':
        if (t/'fail_switch').exists() and a[2].endswith('https-current'):
            (t/'fail_switch').unlink();sys.exit(1)
        os.replace(a[1],a[2])
    else:sys.exit(subprocess.run(['/bin/mv']+a).returncode)
elif name=='sync':pass
elif name=='sleep':pass
elif name=='killall':
    assert a==['-USR1','caddy']
    with (t/'reloads').open('a') as f:f.write('reload\n')
    if not (t/'stale').exists():
        p=t/'robot/credentials/https-fullchain.pem'
        if p.exists():(t/'served.pem').write_bytes(p.read_bytes())
elif name=='caddy':
    assert a[0]=='validate'
    sys.exit(int((t/'fail_validate').exists()))
elif name=='openssl':
    if a[0]=='s_client':
        assert '-verify_return_error' in a and '-verify_hostname' in a
        if (t/'served.pem').exists():sys.stdout.buffer.write((t/'served.pem').read_bytes())
        else:sys.exit(1)
    else:os.execv(os.environ['REAL_OPENSSL'],[os.environ['REAL_OPENSSL']]+a)
elif name=='curl':
    assert '-k' not in a and '--insecure' not in a and '--resolve' in a
    print('503' if (t/'unhealthy').exists() else '401',end='')
else:raise AssertionError(name)
'''


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory()
        cls.fixtures = Path(cls.shared.name)
        for name, host, days in [('old','mattjoslin-valetudo.duckdns.org',30),
                                 ('new','mattjoslin-valetudo.duckdns.org',40),
                                 ('wrong','wrong.example',30),
                                 ('short','mattjoslin-valetudo.duckdns.org',1)]:
            subprocess.run([OPENSSL,'req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256',
                            '-nodes','-days',str(days),'-subj','/CN='+host,'-addext','subjectAltName=DNS:'+host,
                            '-keyout',str(cls.fixtures/(name+'.key')),'-out',str(cls.fixtures/(name+'.pem'))],
                           check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.t = Path(self.temp.name)
        self.robot = self.t/'robot'
        self.directory = self.robot/'credentials'
        self.directory.mkdir(parents=True)
        self.bin = self.t/'bin';self.bin.mkdir()
        for name in ['flock','timeout','mv','sync','sleep','killall','openssl','curl']:
            p=self.bin/name;p.write_text(TOOLS);p.chmod(0o755)
        p=self.robot/'caddy';p.write_text(TOOLS);p.chmod(0o755)
        (self.robot/'https_proxy.Caddyfile').touch()
        (self.robot/'https_cert_state.sh').write_text((REPO/'https_cert_state.sh').read_text())
        self.script=self.t/'install.sh'
        self.script.write_text((REPO/'https_cert_install.sh').read_text().replace('/data/vacuumstreamer',str(self.robot)))
        (self.directory/'https-fullchain.pem').write_bytes((self.fixtures/'old.pem').read_bytes())
        (self.directory/'https-privkey.pem').write_bytes((self.fixtures/'old.key').read_bytes())
        (self.t/'served.pem').write_bytes((self.fixtures/'old.pem').read_bytes())
        self.trust=self.t/'trust.pem'
        self.trust.write_bytes(b''.join((self.fixtures/(n+'.pem')).read_bytes() for n in ['old','new','wrong','short']))
        self.env={**os.environ,'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],'CERT_TEST':str(self.t),
                  'REAL_OPENSSL':OPENSSL,'SSL_CERT_FILE':str(self.trust),'SSL_CERT_DIR':str(self.t/'empty'),
                  'SSH_CONNECTION':'192.168.1.106 4321 192.168.1.31 22','SSH_ORIGINAL_COMMAND':'install'}

    def frame(self, name='new', key=None):
        bundle=(self.fixtures/(name+'.pem')).read_bytes()+b'\n'+(self.fixtures/((key or name)+'.key')).read_bytes()
        return f'{len(bundle):06d}\n'.encode()+bundle

    def run_install(self, frame=None, ack=b'commit\n', **env):
        return subprocess.run([SHELL,str(self.script)],input=(frame or self.frame())+ack,
                              capture_output=True,env={**self.env,**env},timeout=20)

    def assert_old(self):
        self.assertEqual((self.directory/'https-fullchain.pem').read_bytes(),(self.fixtures/'old.pem').read_bytes())
        self.assertEqual((self.directory/'https-privkey.pem').read_bytes(),(self.fixtures/'old.key').read_bytes())

    def test_success_and_noop(self):
        self.assertEqual(self.run_install().returncode,0)
        self.assertEqual((self.directory/'https-privkey.pem').stat().st_mode & 0o777,0o600)
        self.assertEqual((self.directory/'https-fullchain.pem').read_bytes(),(self.fixtures/'new.pem').read_bytes())
        before=(self.t/'reloads').read_text()
        self.assertEqual(self.run_install().returncode,0)
        self.assertEqual((self.t/'reloads').read_text(),before)
        self.assertEqual(len(list((self.directory/'https-generations').iterdir())),2)

    def test_source_and_commands(self):
        for env in [{'SSH_CONNECTION':''},{'SSH_CONNECTION':'192.168.1.113 1 2 3'},
                    {'SSH_ORIGINAL_COMMAND':'cert'},{'SSH_ORIGINAL_COMMAND':'install; touch anything'}]:
            self.assertNotEqual(self.run_install(**env).returncode,0)
            self.assert_old()

    def test_bad_certificates_and_mismatched_key(self):
        for frame in [self.frame('wrong'),self.frame('short'),self.frame('new','old'),b'098305\n'+b'x'*98305,
                      b'000010\nshort',b'000008\ninvalid\n']:
            self.assertNotEqual(self.run_install(frame).returncode,0)
            self.assert_old()

    def test_malformed_key_reaches_parser_with_certificate_present(self):
        bundle=(self.fixtures/'new.pem').read_bytes()+b'-----BEGIN PRIVATE KEY-----\nbad\n-----END PRIVATE KEY-----\n'
        self.assertNotEqual(self.run_install(f'{len(bundle):06d}\n'.encode()+bundle).returncode,0)
        self.assert_old()

    def test_untrusted_chain(self):
        self.trust.write_bytes((self.fixtures/'old.pem').read_bytes())
        self.assertNotEqual(self.run_install().returncode,0)
        self.assert_old()

    def test_failed_publication_validation_and_health_roll_back(self):
        for flag in ['fail_switch','fail_validate','stale','unhealthy']:
            with self.subTest(flag=flag):
                (self.t/flag).touch()
                self.assertNotEqual(self.run_install().returncode,0)
                self.assert_old()
                (self.t/flag).unlink(missing_ok=True)

    def test_missing_or_bad_ha_ack_rolls_back(self):
        for ack in [b'',b'reject\n']:
            result=self.run_install(ack=ack)
            self.assertEqual(result.stdout,b'ready\n')
            self.assertNotEqual(result.returncode,0)
            self.assert_old()

    def test_concurrent_upload_refused_and_stalled_upload_bounded(self):
        p=subprocess.Popen([SHELL,str(self.script)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                           env={**self.env,'TIME_SCALE':'0.1'})
        try:
            p.stdin.write(b'000100\n');p.stdin.flush()
            import time
            time.sleep(0.15)
            self.assertNotEqual(self.run_install().returncode,0)
            self.assertNotEqual(p.wait(timeout=4),0)
            self.assert_old()
        finally:
            p.stdin.close();p.stdout.close();p.stderr.close()
            if p.poll() is None:p.kill();p.wait()

    def test_killed_transaction_is_recovered_before_next_install(self):
        p=subprocess.Popen([SHELL,str(self.script)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.env)
        try:
            p.stdin.write(self.frame());p.stdin.flush()
            self.assertEqual(p.stdout.readline(),b'ready\n')
            p.kill();p.wait();p.stdin.close()
            # Recovery function also runs in the proxy before restarting Caddy.
            result=subprocess.run([SHELL,'-c',f'DIR="{self.directory}"; . "{self.robot}/https_cert_state.sh"; https_recover'],
                                  env=self.env,capture_output=True)
            self.assertEqual(result.returncode,0)
            self.assert_old()
        finally:
            if not p.stdin.closed:p.stdin.close()
            p.stdout.close();p.stderr.close()


class HaSyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('ha_sync',REPO/'tools/ha_https_cert_sync.py')
        cls.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.module)

    def test_acknowledges_only_after_verification(self):
        class Input(io.BytesIO):
            def close(self):
                self.saved=self.getvalue()
                super().close()

        class Process:
            def __init__(self):
                self.stdin=Input();self.stdout=io.BytesIO(b'ready\n')
            def wait(self,timeout):return 0

        with tempfile.TemporaryDirectory() as directory:
            cert=Path(directory)/'cert.pem';key=Path(directory)/'key.pem'
            subprocess.run([OPENSSL,'req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
                            '-days','30','-subj','/CN=test','-keyout',str(key),'-out',str(cert)],check=True,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for failure in [False,True]:
                process=Process()
                def verify(expected):
                    self.assertEqual(len(expected),32)
                    self.assertNotIn(b'commit\n',process.stdin.getvalue())
                    if failure:raise ValueError('wrong served certificate')
                with patch.object(self.module,'CERT',cert),patch.object(self.module,'KEY',key), \
                     patch.object(self.module.subprocess,'Popen',return_value=process), \
                     patch.object(self.module.select,'select',return_value=([process.stdout],[],[])), \
                     patch.object(self.module,'verify_served',side_effect=verify):
                    if failure:
                        with self.assertRaises(ValueError):self.module.install()
                        self.assertNotIn(b'commit\n',process.stdin.saved)
                    else:
                        self.module.install()
                        self.assertTrue(process.stdin.saved.endswith(b'commit\n'))

    def test_served_fingerprint_and_expiry_are_independent_checks(self):
        import datetime,hashlib
        class Connection:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def getpeercert(self,binary_form=False):
                if binary_form:return b'test-leaf'
                expiry=datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=days)
                return {'notAfter':expiry.strftime('%b %d %H:%M:%S %Y GMT')}
            def sendall(self,value):self.response=iter(b'HTTP/1.1 401 Unauthorized\r\n')
            def settimeout(self,value):pass
            def recv(self,size):return bytes([next(self.response)])
        from unittest.mock import MagicMock
        connection=Connection();context=MagicMock();context.wrap_socket.return_value=connection
        with patch.object(self.module.ssl,'create_default_context',return_value=context), \
             patch.object(self.module.socket,'create_connection',return_value=connection):
            days=30
            with self.assertRaises(ValueError):self.module.verify_served(b'wrong-fingerprint')
            self.module.verify_served(hashlib.sha256(b'test-leaf').digest())
            days=1
            with self.assertRaises(ValueError):self.module.verify_served()
            self.assertTrue(all(c.kwargs['server_hostname']==self.module.HOST for c in context.wrap_socket.call_args_list))


if __name__ == '__main__':
    unittest.main()
