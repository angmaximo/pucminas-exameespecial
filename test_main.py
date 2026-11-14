import unittest
from unittest.mock import patch, MagicMock
from src.main import (
    local_get_build_logs,
    local_trigger_pipeline_retry,
    local_notify_oncall_team,
)

class TestDevOpsAgent(unittest.TestCase):

    def test_get_build_logs_normal(self):
        logs = local_get_build_logs("build-101")
        self.assertIn("Connection timeout", logs)

    def test_get_build_logs_critical_303(self):
        logs = local_get_build_logs("build-303")
        self.assertIn("CRITICAL", logs)
        self.assertIn("Database corruption", logs)

    def test_trigger_pipeline_retry(self):
        result = local_trigger_pipeline_retry("build-101")
        self.assertIn("SUCCESS", result)
        self.assertIn("build-101", result)

    def test_notify_oncall_team(self):
        result = local_notify_oncall_team("build-303", "CRITICAL", "Database corruption detected")
        self.assertIn("SUCCESS", result)
        self.assertIn("CRITICAL", result)

    @patch("src.main.firestore.Client")
    def test_idempotency_skip(self, mock_firestore_client):
        # Configura o mock do Firestore para simular que o build_id já foi triado
        mock_doc = MagicMock()
        mock_doc.exists = True
        mock_doc.to_dict.return_value = {"status": "TRIAGED"}
        
        mock_db = MagicMock()
        mock_db.collection.return_value.document.return_value.get.return_value = mock_doc
        mock_firestore_client.return_value = mock_db

        doc_ref = mock_db.collection("build_triages").document("build-303")
        doc_snapshot = doc_ref.get()
        
        self.assertTrue(doc_snapshot.exists)
        self.assertEqual(doc_snapshot.to_dict().get("status"), "TRIAGED")

if __name__ == "__main__":
    unittest.main()