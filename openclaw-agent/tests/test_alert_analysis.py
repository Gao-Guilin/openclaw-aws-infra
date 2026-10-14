import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

import boto3
from botocore.stub import ANY, Stubber


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "aws-alert-analysis"
    / "alert_analysis.py"
)
SPEC = importlib.util.spec_from_file_location("openclaw_alert_analysis", MODULE_PATH)
alert = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(alert)


class AlertAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(
            os.environ,
            {
                "AWS_EC2_METADATA_DISABLED": "true",
                "AWS_REGION": "ap-northeast-1",
            },
            clear=False,
        )
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_sanitize_redacts_sensitive_keys_and_string_values(self):
        aws_access_key = "AKIA" + "1234567890ABCDEF"
        value = {
            "api_key": "plain-secret",
            "message": "Authorization: Bearer abc.def token=visible",
            "nested": [aws_access_key],
        }
        sanitized = alert.sanitize(value)
        self.assertEqual(sanitized["api_key"], "***REDACTED***")
        self.assertNotIn("abc.def", sanitized["message"])
        self.assertNotIn("visible", sanitized["message"])
        self.assertNotIn(aws_access_key, sanitized["nested"][0])

    def test_normalize_sns_wrapped_cloudwatch_alarm(self):
        payload = {
            "Type": "Notification",
            "MessageId": "sns-123",
            "Timestamp": "2026-07-28T01:00:00Z",
            "Message": json.dumps(
                {
                    "AlarmName": "openclaw-high-cpu",
                    "NewStateValue": "ALARM",
                    "NewStateReason": "Threshold crossed",
                }
            ),
        }
        normalized = alert.normalize_alert(payload)
        self.assertEqual(normalized["event_type"], "cloudwatch_alarm_notification")
        self.assertEqual(normalized["event_id"], "sns-123")
        self.assertEqual(normalized["alert_name"], "openclaw-high-cpu")
        self.assertEqual(normalized["state"], "ALARM")

    def test_normalize_eventbridge_cloudwatch_alarm(self):
        payload = {
            "id": "event-1",
            "source": "aws.cloudwatch",
            "detail-type": "CloudWatch Alarm State Change",
            "time": "2026-07-28T01:00:00Z",
            "detail": {
                "alarmName": "openclaw-errors",
                "state": {"value": "ALARM", "reason": "5xx threshold"},
            },
        }
        normalized = alert.normalize_alert(payload)
        self.assertEqual(normalized["event_type"], "cloudwatch_alarm_state_change")
        self.assertEqual(normalized["event_id"], "event-1")
        self.assertEqual(normalized["message"], "5xx threshold")

    def test_normalize_ecs_task_failure(self):
        payload = {
            "id": "ecs-event",
            "source": "aws.ecs",
            "detail-type": "ECS Task State Change",
            "detail": {
                "taskArn": "arn:aws:ecs:ap-northeast-1:123:task/demo",
                "lastStatus": "STOPPED",
                "stoppedReason": "Essential container exited",
            },
        }
        normalized = alert.normalize_alert(payload)
        self.assertEqual(normalized["event_type"], "ecs_task_state_change")
        self.assertEqual(normalized["state"], "STOPPED")
        self.assertIn("Essential container", normalized["message"])

    def test_alert_id_is_deterministic(self):
        normalized = alert.normalize_alert(
            {"AlarmName": "demo", "NewStateValue": "ALARM", "NewStateReason": "failure"}
        )
        first = alert.build_alert_id(normalized, "job-1")
        second = alert.build_alert_id(normalized, "job-1")
        self.assertEqual(first, second)
        self.assertRegex(first, r"^alert-[0-9a-f]{32}$")

    def test_empty_alert_fails_validation(self):
        errors = alert.validate_normalized_alert(alert.normalize_alert({}))
        self.assertEqual(errors[0]["code"], "alert_context_missing")

    def test_alarm_state_with_timeout_is_high(self):
        normalized = alert.normalize_alert(
            {"alert_name": "local-test", "state": "ALARM", "message": "dependency timeout"}
        )
        severity = alert.classify_severity(
            normalized, {"ok": True, "configured": False}
        )
        self.assertEqual(severity, "high")

    def test_persist_alert_record_uses_expected_table(self):
        client = boto3.client(
            "dynamodb",
            region_name="ap-northeast-1",
            aws_access_key_id="test",
            aws_secret_access_key="test",
            aws_session_token="test",
        )
        with Stubber(client) as stubber:
            stubber.add_response(
                "put_item",
                {},
                {"TableName": "alerts-table", "Item": ANY},
            )
            result = alert.persist_alert_record(
                "ap-northeast-1",
                "alerts-table",
                {
                    "alert_id": "alert-123",
                    "job_id": "job-123",
                    "task_type": "alert_analysis",
                    "event_type": "generic_alert",
                    "alert_name": "demo",
                    "alert_state": "ALARM",
                    "severity": "medium",
                    "human_action_required": True,
                    "status": "success",
                    "timestamp_utc": "2026-07-28T00:00:00+00:00",
                    "payload_sha256": "0" * 64,
                    "summary": {},
                    "confirmed_facts": [],
                    "likely_causes": [],
                    "unknowns": [],
                    "recommended_next_checks": [],
                    "warnings": [],
                    "errors": [],
                },
                client=client,
            )
        self.assertTrue(result["ok"])
        self.assertEqual(result["alert_id"], "alert-123")

    def test_main_persists_when_explicitly_enabled(self):
        payload = {
            "id": "event-persist",
            "source": "aws.ecs",
            "detail-type": "ECS Task State Change",
            "detail": {
                "taskArn": "arn:aws:ecs:ap-northeast-1:123:task/demo",
                "lastStatus": "STOPPED",
                "stoppedReason": "Essential container exited",
            },
        }
        with patch.dict(
            os.environ,
            {
                "OPENCLAW_ALERT_JSON": json.dumps(payload),
                "OPENCLAW_ALERT_REQUIRE_PAYLOAD": "true",
                "OPENCLAW_ALERT_PERSIST_DYNAMODB": "true",
                "DYNAMODB_ALERTS_TABLE": "alerts-table",
            },
            clear=False,
        ), patch.object(alert, "check_sts", return_value={"ok": True}), patch.object(
            alert, "describe_cloudwatch_alarm", return_value={"ok": True, "configured": False}
        ), patch.object(
            alert, "collect_recent_log_events", return_value={"ok": True, "configured": False}
        ), patch.object(
            alert,
            "persist_alert_record",
            return_value={"ok": True, "enabled": True, "table_name": "alerts-table", "alert_id": "persisted"},
        ) as persist, patch("builtins.print") as mocked_print:
            rc = alert.main()

        output = json.loads(mocked_print.call_args.args[0])
        self.assertEqual(rc, 0)
        self.assertTrue(output["overall_ok"])
        self.assertTrue(output["artifacts"]["dynamodb_alert"]["ok"])
        persist.assert_called_once()

    def test_main_rejects_missing_input_by_default(self):
        with patch.dict(
            os.environ,
            {
                "OPENCLAW_ALERT_JSON": "",
                "OPENCLAW_ALERT_FILE": "",
                "OPENCLAW_EVENT_JSON": "",
                "OPENCLAW_ALERT_NAME": "",
                "OPENCLAW_ALARM_NAME": "",
                "OPENCLAW_ALERT_MESSAGE": "",
                "OPENCLAW_ALERT_REQUIRE_PAYLOAD": "true",
            },
            clear=False,
        ), patch.object(alert, "check_sts", return_value={"ok": True}), patch.object(
            alert, "describe_cloudwatch_alarm", return_value={"ok": True, "configured": False}
        ), patch.object(
            alert, "collect_recent_log_events", return_value={"ok": True, "configured": False}
        ), patch("builtins.print") as mocked_print:
            rc = alert.main()
        self.assertEqual(rc, 1)
        output = json.loads(mocked_print.call_args.args[0])
        self.assertFalse(output["overall_ok"])
        self.assertIn("alert_payload_required", {item["code"] for item in output["errors"]})


if __name__ == "__main__":
    unittest.main()
