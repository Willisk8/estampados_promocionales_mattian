import unittest

from scripts.data_quality.normalize_remote_records import compatible


class RemoteNormalizationTests(unittest.TestCase):
    def test_lost_character_requires_full_source_match(self):
        self.assertEqual(compatible('Tula ecol\ufffdgica', {'Tula ecológica'}), 'Tula ecológica')
        self.assertIsNone(compatible('CALLE 1 ?', {'CALLE 2 Á'}))

    def test_ambiguous_and_damaged_sources_are_rejected(self):
        self.assertIsNone(compatible('PE?A', {'PEÑA', 'PERA'}))
        self.assertIsNone(compatible('PE?A', {'PE?A'}))

    def test_multiple_question_marks_represent_one_lost_character(self):
        self.assertEqual(compatible('PE??A', {'PEÑA'}), 'PEÑA')
        self.assertIsNone(compatible('PE??A', {'PEREIRA'}))
        self.assertEqual(compatible('COMPA????A', {'COMPAÑÍA'}), 'COMPAÑÍA')

    def test_punctuation_is_not_ignored(self):
        self.assertIsNone(compatible('PE?A S.A.S.', {'PEÑA SAS'}))


if __name__ == '__main__':
    unittest.main()
