import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('registration_keepalive', ROOT/'scripts/registration_keepalive.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class RegistrationKeepaliveTests(unittest.TestCase):
    def test_parse_typed_table(self):
        t='name: 100#1\n value: sip:8.8.4.4:4000\n type: str\nname: 100#1#ts\n value: 995\n type: int\n'
        self.assertEqual(m.parse_table(t),{'100#1':'sip:8.8.4.4:4000','100#1#ts':995})
    def test_parser_fails_closed(self):
        for t in ['error: 500 no table','name: 100#1\nmalformed']:
            with self.assertRaises(ValueError):m.parse_table(t)
    def test_accepts_two_authenticated_100_peers(self):
        t={'100#1':'sip:8.8.4.4:4000','100#1#ts':995,
           '100#2':'sip:8.8.4.4:4001','100#2#ts':998,
           '105#1':'sip:8.8.4.4:4002','105#1#ts':998}
        peers=m.select_peers(t,['100'],1000,3600,5)
        self.assertEqual(len(peers),2)
        self.assertEqual([x['slot'] for x in peers],[1,2])
        self.assertEqual(t['100#1#ts'],995)  # OPTIONS must not renew auth state.
    def test_stale_future_untyped_or_missing_auth_rejected(self):
        for ts in [0,1001,'995',None]:
            t={'100#1':'sip:8.8.4.4:4000','100#1#ts':ts}
            self.assertEqual(m.select_peers(t,['100'],1000,600,5),[])
    def test_private_or_invalid_destinations_not_probed(self):
        for p in ['sip:127.0.0.1:5060','sip:10.8.0.2:5060',
                  'sip:169.254.169.254:8080','sip:224.0.0.1:5060',
                  'sip:8.8.4.4:22','sip:8.8.4.4:65536',
                  'sip:8.8.4.4:5060;transport=tcp']:
            self.assertEqual(m.select_peers({'100#1':p,'100#1#ts':995},['100'],1000,600,5),[])
    def test_deduplicate_and_bound_targets(self):
        t={}
        for i in range(1,6):t[f'100#{i}']='sip:8.8.4.4:4000';t[f'100#{i}#ts']=995
        self.assertEqual(len(m.select_peers(t,['100'],1000,600,5)),1)
        t['100#2']='sip:8.8.4.4:4001'
        self.assertEqual(len(m.select_peers(t,['100'],1000,600,1)),1)
    def test_only_numeric_allowlist(self):
        with self.assertRaises(ValueError):m.select_peers({},['cw1'],1000,600,5)
        with self.assertRaises(ValueError):m.select_peers({},['app_100'],1000,600,5)
    def test_empty_rpc_body_is_explicit_string(self):
        with patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'','')) as run:
            m.rpc('unix:/tmp/test','tm.t_uac_start',['OPTIONS','sip:100@8.8.4.4:4000','.','udp:8.8.8.8:17060','From: x\r\nTo: y\r\n',''])
            args=run.call_args.args[0]
            self.assertEqual(args[-1],'s:')
            self.assertIn('s:OPTIONS',args)
    def test_rpc_reports_fault_even_if_kamcmd_exit_zero(self):
        with patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'error: 400 - failure\n','')):
            with self.assertRaises(RuntimeError):m.rpc('unix:/tmp/test','tm.t_uac_start',[])
    def test_headers_are_options_metadata_only(self):
        h=m.make_headers('100','sip.example.com')
        self.assertIn('Call-ID: coovoxka-',h)
        self.assertNotIn('Authorization:',h)
        self.assertNotIn('REGISTER',h)
    def test_status_is_private(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'status.json';m.write_status(p,{'a':1})
            self.assertEqual(p.stat().st_mode & 0o777,0o600)

if __name__=='__main__':unittest.main()
