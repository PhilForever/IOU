"""Release destination, integrity, classification and retry-safety checks; no network."""
import hashlib
import json
from pathlib import Path
import shutil
import unittest
import uuid
from zipfile import ZipFile

import curseforge_upload as publisher


class PublishingTests(unittest.TestCase):
    def setUp(self):
        temporary_root = Path(__file__).resolve().parents[1] / 'artifacts'
        self.root = temporary_root / ('publisher-test-' + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        def cleanup():
            if self.root.resolve().parent != temporary_root.resolve() or not self.root.name.startswith('publisher-test-'):
                raise ValueError('Refusing cleanup outside the publishing test directory.')
            shutil.rmtree(self.root)
        self.addCleanup(cleanup)
        self.archive = self.root / 'IOU-0.2.0.zip'
        with ZipFile(self.archive, 'w') as package:
            package.writestr('IOU/IOU.toc', '## Interface: 16001\n## Version: 0.2.0\n## X-Curse-Project-ID: 1746575\n')
            package.writestr('IOU/CHANGELOG.md', '# Changelog\nSynthetic release.\n')
        self.checksum = self.archive.with_suffix('.zip.sha256')
        self.write_checksum()
        self.receipt = self.root / 'receipt.json'

    def write_checksum(self):
        self.checksum.write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest() + '  ' + self.archive.name + '\n')

    def test_release_classification_and_invalid_tags(self):
        for version, expected in [('0.2.0', 'release'), ('0.3.0', 'release'), ('0.3.0-alpha.2', 'alpha'), ('0.3.0-beta.1', 'beta'), ('0.3.0-rc.1', 'beta')]:
            self.assertEqual(publisher.release_type(publisher.release_version('v' + version)), expected)
        for tag in ['main', 'v../../x', 'v0.2.0; echo bad', '0.2.0', 'v0.2.0\n']:
            with self.assertRaises(ValueError):
                publisher.release_version(tag)

    def test_verified_release_upload_and_receipt_prevent_duplicate_post(self):
        calls = []
        def request(path, token, data=None, content_type=None):
            self.assertEqual(token, 'synthetic-token')
            calls.append(path)
            if path == '/api/game/versions':
                return [{'id': 55, 'name': '1.60.1'}, {'id': 99, 'name': '12.0.1'}]
            self.assertEqual(path, '/api/projects/1746575/upload-file')
            self.assertTrue(content_type.startswith('multipart/form-data; boundary='))
            self.assertIn(b'"gameVersions": [55]', data)
            self.assertIn(b'"releaseType": "release"', data)
            self.assertIn(b'filename="IOU-0.2.0.zip"', data)
            self.assertIn(self.archive.read_bytes(), data)
            self.assertNotIn(b'synthetic-token', data)
            return {'id': 123}
        first = publisher.publish(self.archive, self.checksum, 'v0.2.0', 1746575, 'synthetic-token', self.receipt, request)
        second = publisher.publish(self.archive, self.checksum, 'v0.2.0', 1746575, 'synthetic-token', self.receipt, request)
        self.assertEqual(first, second)
        self.assertEqual(first['fileId'], 123)
        self.assertEqual(len(calls), 2)

    def test_bad_checksum_tag_or_project_is_rejected_before_network(self):
        def no_network(*args):
            self.fail('Invalid release made a network request')
        for tag, project in [('v0.3.0', 1746575), ('v0.2.0', 12)]:
            with self.assertRaises(ValueError):
                publisher.publish(self.archive, self.checksum, tag, project, 'synthetic', self.receipt, no_network)
        self.checksum.write_text('0' * 64 + '  ' + self.archive.name)
        with self.assertRaises(ValueError):
            publisher.publish(self.archive, self.checksum, 'v0.2.0', 1746575, 'synthetic', self.receipt, no_network)

    def test_ambiguous_or_missing_forever_version_is_rejected(self):
        for versions in [[], {}, [{'id': True, 'name': '1.60.1'}], [{'id': 1, 'name': '1.60.1'}, {'id': 2, 'name': '1.60.1'}]]:
            with self.assertRaises(ValueError):
                publisher.game_version_id(versions)

    def test_conflicting_receipt_cannot_hide_wrong_project_or_content(self):
        self.receipt.write_text(json.dumps({'projectId': 12, 'tag': 'v0.2.0', 'sha256': 'wrong', 'fileId': 123}))
        with self.assertRaises(ValueError):
            publisher.publish(self.archive, self.checksum, 'v0.2.0', 1746575, 'synthetic', self.receipt, lambda *args: self.fail('Conflicting receipt contacted API'))

    def test_ambiguous_post_result_is_not_retried_or_recorded_as_success(self):
        calls = []
        def request(path, *args):
            calls.append(path)
            return [{'id': 1, 'name': '1.60.1'}] if path.endswith('/versions') else {'id': True}
        with self.assertRaises(ValueError):
            publisher.publish(self.archive, self.checksum, 'v0.2.0', 1746575, 'synthetic', self.receipt, request)
        self.assertEqual(len(calls), 2)
        self.assertFalse(self.receipt.exists())


if __name__ == '__main__':
    unittest.main()
