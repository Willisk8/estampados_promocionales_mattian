import unittest

from scripts.data_quality.recover_historical_names import candidate_name
from scripts.data_quality.audit_live_snapshot import repair


class RecoveryTests(unittest.TestCase):
    def test_recovers_only_missing_character(self):
        self.assertEqual(candidate_name('COMPA??IA SIGRA S.A.', {'COMPAÑIA SIGRA S.A.'}), 'COMPAÑIA SIGRA S.A.')

    def test_rejects_changed_name(self):
        self.assertIsNone(candidate_name('COMPA??IA SIGRA S.A.', {'COMPAÑIA DIFERENTE S.A.'}))

    def test_rejects_ambiguous_candidates(self):
        self.assertIsNone(candidate_name('PE?A', {'PEÑA', 'PERA'}))

    def test_preserves_significant_punctuation(self):
        self.assertIsNone(candidate_name('PE?A & CIA', {'PEÑA CIA'}))

    def test_cp1252_repair(self):
        original = 'CÓRDOBA'.encode('utf-8').decode('cp1252')
        self.assertEqual(repair(original), 'CÓRDOBA')


if __name__ == '__main__':
    unittest.main()
