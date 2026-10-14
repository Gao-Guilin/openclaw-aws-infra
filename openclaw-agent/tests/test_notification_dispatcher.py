import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "_shared"
    / "notification_dispatcher.py"
)
SPEC = importlib.util.spec_from_file_location("openclaw_notification_dispatcher", MODULE_PATH)
notify = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(notify)


class NotificationDispatcherTests(unittest.TestCase):
    def test_alert_notification_uses_allowlisted_fields_only(self):
        result = {
            "task_type": "alert_analysis",
            "job_id": "job-alert",
            "status": "success",
            "overall_ok": True,
            "timestamp_utc": "2026-07-30T00:00:00+00:00",
            "alert_id": "alert-123",
            "severity": "high",
            "human_action_required": True,
            "sanitized_alert_payload": {
                "api_key": "must-not-leak",
                "message": "raw diagnostic",
            },
            "confirmed_facts": ["private evidence"],
        }

        notification = notify.build_notification(result, 0, {"OPENCLAW_ENVIRONMENT": "dev"})
        self.assertIsNotNone(notification)
        message = notification["message"]
        rendered = json.dumps(message)

        self.assertEqual(message["event_type"], "alert_analysis_completed")
        self.assertEqual(message["severity"], "high")
        self.assertNotIn("must-not-leak", rendered)
        self.assertNotIn("raw diagnostic", rendered)
        self.assertNotIn("private evidence", rendered)

    def test_report_notification_contains_only_safe_artifact_uris(self):
        result = {
            "task_type": "report_generation",
            "job_id": "job-report",
            "status": "success",
            "overall_ok": True,
            "report_id": "report-123",
            "source_task_type": "alert_analysis",
            "artifacts": {
                "s3": {
                    "markdown_uri": "s3://reports-bucket/reports/report.md",
                    "summary_uri": "s3://reports-bucket/reports/report.summary.json",
                },
                "local": {"path": "/app/runtime/private"},
            },
        }

        notification = notify.build_notification(result, 0, {})
        self.assertEqual(notification["message"]["event_type"], "report_generation_completed")
        self.assertEqual(
            notification["message"]["markdown_s3_uri"],
            "s3://reports-bucket/reports/report.md",
        )
        self.assertNotIn("/app/runtime/private", json.dumps(notification["message"]))

    def test_failed_task_generates_generic_failure_notification(self):
        result = {
            "task_type": "daily_inspection",
            "job_id": "job-failed",
            "status": "failed",
            "overall_ok": False,
            "errors": [
                {"code": "aws_check_failed", "message": "Authorization: secret"}
            ],
        }

        notification = notify.build_notification(result, 1, {})
        message = notification["message"]
        self.assertEqual(message["event_type"], "task_failed")
        self.assertEqual(message["error_codes"], ["aws_check_failed"])
        self.assertNotIn("Authorization", json.dumps(message))

    def test_successful_non_notifiable_task_is_skipped(self):
        result = {
            "task_type": "healthcheck",
            "job_id": "job-health",
            "status": "success",
            "overall_ok": True,
        }
        self.assertIsNone(notify.build_notification(result, 0, {}))

    def test_publish_notification_calls_sns_with_attributes(self):
        client = Mock()
        client.publish.return_value = {"MessageId": "message-123"}
        notification = {
            "subject": "OpenClaw-AWS report ready: success",
            "message": {
                "event_type": "report_generation_completed",
                "task_type": "report_generation",
                "status": "success",
            },
        }

        outcome = notify.publish_notification(
            "arn:aws:sns:ap-northeast-1:123456789012:topic",
            notification,
            "ap-northeast-1",
            client=client,
        )

        self.assertTrue(outcome["ok"])
        self.assertEqual(outcome["message_id"], "message-123")
        kwargs = client.publish.call_args.kwargs
        self.assertEqual(kwargs["MessageAttributes"]["event_type"]["StringValue"], "report_generation_completed")
        self.assertNotIn("arn:aws:sns", json.dumps(outcome))

    def test_load_result_rejects_non_object_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text("[]", encoding="utf-8")
            with self.assertRaises(ValueError):
                notify.load_result(str(path))

    def test_main_skips_when_notifications_are_disabled(self):
        with patch.dict(os.environ, {"OPENCLAW_SNS_NOTIFY_ENABLED": "false"}, clear=False), patch(
            "builtins.print"
        ) as mocked_print, patch.object(notify, "parse_args", return_value=type("Args", (), {"result_file": "", "exit_code": 0})()):
            rc = notify.main()
        self.assertEqual(rc, 0)
        self.assertIn("notifications_disabled", mocked_print.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
