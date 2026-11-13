import unittest
from unittest.mock import patch, MagicMock
from src.main import (
    local_get_build_logs,
    local_trigger_pipeline_retry,
    local_notify_oncall_team,
    check_idempotency
)

class TestDevOpsAgent(unittest.TestCase):

    def test_get_build_logs_critical(self):
        logs = local_get_build_logs("build-303")
        self.assertIn("CRITICAL", logs)
        self.assertIn("Database corruption", logs)

    def test_trigger_pipeline_retry(self):
        result = local_trigger_pipeline_retry("build-101")
        self.assertIsInstance(result, str)
        self.assertIn("successfully triggered", result)

    def test_notify_oncall_team(self):
        result = local_notify_oncall_team("build-303", "CRITICAL", "Database corruption detected")
        self.assertIsInstance(result, str)
        self.assertIn("Incident ticket successfully opened", result)

    @patch("src.main.db")
    def test_idempotency_skip(self, mock_db):
        mock_doc = MagicMock()
        mock_doc.exists = True
        mock_doc.to_dict.return_value = {"status": "TRIAGED"}
        mock_db.collection.return_value.document.return_value.get.return_value = mock_doc

        result = check_idempotency("build-303")
        self.assertTrue(result)

    @patch("src.main.db")
    def test_idempotency_not_found(self, mock_db):
        mock_doc = MagicMock()
        mock_doc.exists = False
        mock_db.collection.return_value.document.return_value.get.return_value = mock_doc

        result = check_idempotency("build-999")
        self.assertFalse(result)

if __name__ == "__main__":
    unittest.main()