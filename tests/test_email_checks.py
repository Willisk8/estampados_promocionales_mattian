import unittest
from scripts.data_quality.email_checks import email_syntax, check_domain


class EmailChecksTests(unittest.TestCase):
    def test_free_domains_are_allowed_and_local_part_preserved(self):
        for domain in ['gmail.com','hotmail.com','outlook.com']:
            self.assertEqual(email_syntax('Conjunto+Admin@'+domain.upper()), ('Conjunto+Admin@'+domain,domain,'VALID'))

    def test_bad_syntax_is_rejected(self):
        for value in ['a..b@gmail.com','admin@-gmail.com','admin@gmail','conjunto @ gmail.com']:
            self.assertEqual(email_syntax(value)[2],'INVALID_FORMAT')

    def test_null_mx_and_timeout_differ(self):
        self.assertEqual(check_domain('example.com',lambda *_:{'Status':0,'Answer':[{'type':15,'data':'0 .'}]}),'NULL_MX')
        self.assertEqual(check_domain('example.com',lambda *_:{'Status':2}),'UNKNOWN')

    def test_dns_fallback(self):
        records={'MX':{'Status':0},'A':{'Status':0,'Answer':[{'type':1,'data':'192.0.2.1'}]},'AAAA':{'Status':0},'TXT':{'Status':0}}
        self.assertEqual(check_domain('example.com',lambda _,kind:records[kind]),'ADDRESS_FALLBACK')
        records['TXT']['Answer']=[{'type':16,'data':'"v=spf1 -all"'}]
        self.assertEqual(check_domain('example.com',lambda _,kind:records[kind]),'NO_MAIL')
