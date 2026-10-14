import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "_shared"
    / "efs_history_store.py"
)
SPEC = importlib.util.spec_from_file_location("openclaw_efs_history_store", MODULE_PATH)
history = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(history)


class EfsHistoryStoreTests(unittest.TestCase):
    def test_archive_writes_allowlisted_sanitized_record(self):
        result = {
            "task_type": "alert_analysis",
            "job_id": "job-123",
            "status": "success",
            "overall_ok": True,
            "timestamp_utc": "2026-07-30T01:00:00+00:00",
            "summary": {"text": "authorization=top-secret"},
            "sanitized_alert_payload": {"authorization": "Bearer must-not-persist"},
            "api_key": "must-not-persist",
            "warnings": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_file = root / "result.json"
            result_file.write_text(json.dumps(result), encoding="utf-8")
            archived_at = datetime(2026, 7, 30, 2, 0, tzinfo=timezone.utc)

            response = history.archive_result(
                result_file=result_file,
                history_dir=root / "history",
                exit_code=0,
                task_types=("alert_analysis",),
                archived_at=archived_at,
            )

            stored = json.loads(Path(response["history_file"]).read_text(encoding="utf-8"))

        self.assertTrue(response["ok"])
        self.assertTrue(response["archived"])
        self.assertEqual(stored["task_type"], "alert_analysis")
        serialized = json.dumps(stored)
        self.assertNotIn("must-not-persist", serialized)
        self.assertNotIn("sanitized_alert_payload", stored)
        self.assertIn("***REDACTED***", serialized)

    def test_archive_is_idempotent_for_same_result_and_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_file = root / "result.json"
            result_file.write_text(
                json.dumps(
                    {
                        "task_type": "alert_analysis",
                        "job_id": "same-job",
                        "timestamp_utc": "2026-07-30T01:00:00+00:00",
                    }
                ),
                encoding="utf-8",
            )
            archived_at = datetime(2026, 7, 30, 2, 0, tzinfo=timezone.utc)
            first = history.archive_result(
                result_file, root / "history", 0, ("alert_analysis",), archived_at=archived_at
            )
            second = history.archive_result(
                result_file,
                root / "history",
                0,
                ("alert_analysis",),
                archived_at=archived_at + timedelta(hours=1),
            )

        self.assertFalse(first["already_exists"])
        self.assertTrue(second["already_exists"])
        self.assertEqual(first["history_file"], second["history_file"])

    def test_archive_skips_unconfigured_task_type(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_file = root / "result.json"
            result_file.write_text(
                json.dumps({"task_type": "healthcheck", "job_id": "job"}),
                encoding="utf-8",
            )
            response = history.archive_result(
                result_file, root / "history", 0, ("alert_analysis",)
            )

        self.assertTrue(response["ok"])
        self.assertFalse(response["archived"])
        self.assertEqual(response["reason"], "task_type_not_enabled")

    def test_archive_always_excludes_report_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_file = root / "result.json"
            result_file.write_text(
                json.dumps({"task_type": "report_generation", "job_id": "job"}),
                encoding="utf-8",
            )
            response = history.archive_result(
                result_file,
                root / "history",
                0,
                ("report_generation", "alert_analysis"),
            )

        self.assertFalse(response["archived"])
        self.assertEqual(response["reason"], "report_generation_excluded")

    def test_recent_history_filters_old_invalid_and_unconfigured_files(self):
        reference = datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.mkdir(exist_ok=True)
            records = [
                {
                    "history_schema_version": "1.0",
                    "task_type": "alert_analysis",
                    "job_id": "newest",
                    "timestamp_utc": (reference - timedelta(hours=1)).isoformat(),
                    "overall_ok": True,
                },
                {
                    "history_schema_version": "1.0",
                    "task_type": "cost_inspection",
                    "job_id": "older",
                    "timestamp_utc": (reference - timedelta(hours=2)).isoformat(),
                    "overall_ok": True,
                },
                {
                    "history_schema_version": "1.0",
                    "task_type": "alert_analysis",
                    "job_id": "too-old",
                    "timestamp_utc": (reference - timedelta(hours=200)).isoformat(),
                },
                {
                    "history_schema_version": "1.0",
                    "task_type": "healthcheck",
                    "job_id": "not-enabled",
                    "timestamp_utc": (reference - timedelta(hours=1)).isoformat(),
                },
            ]
            for index, record in enumerate(records):
                (root / f"{index}.json").write_text(json.dumps(record), encoding="utf-8")
            (root / "invalid.json").write_text("not-json", encoding="utf-8")

            response = history.read_recent_history(
                root,
                lookback_hours=168,
                max_items=1,
                task_types=("alert_analysis", "cost_inspection"),
                reference=reference,
            )

        self.assertEqual(response["candidate_count"], 2)
        self.assertEqual(response["included_count"], 1)
        self.assertEqual(response["records"][0]["job_id"], "newest")
        self.assertEqual(response["truncated_count"], 1)
        self.assertEqual(response["skipped_invalid"], 1)
        self.assertEqual(response["skipped_old"], 1)
        self.assertEqual(response["skipped_task_type"], 1)

    def test_build_aggregate_payload_counts_records_and_failures(self):
        payload = history.build_aggregate_payload(
            {
                "history_dir": "/runtime/history",
                "lookback_hours": 168,
                "candidate_count": 2,
                "included_count": 2,
                "truncated_count": 0,
                "skipped_invalid": 0,
                "window_start": "2026-07-23T00:00:00+00:00",
                "window_end": "2026-07-30T00:00:00+00:00",
                "records": [
                    {
                        "task_type": "alert_analysis",
                        "job_id": "a",
                        "status": "success",
                        "overall_ok": True,
                        "severity": "high",
                        "warnings": ["warning-a"],
                        "recommended_next_checks": ["review-a"],
                    },
                    {
                        "task_type": "cost_inspection",
                        "job_id": "b",
                        "status": "failed",
                        "overall_ok": False,
                        "severity": "unknown",
                        "errors": [{"code": "cost_failed", "message": "failed"}],
                    },
                ],
            }
        )

        self.assertFalse(payload["overall_ok"])
        self.assertEqual(payload["aggregation"]["included_count"], 2)
        self.assertEqual(payload["aggregation"]["task_type_counts"]["alert_analysis"], 1)
        self.assertEqual(payload["errors"][0]["error"], "cost_failed")
        self.assertIn("review-a", payload["recommendations"])

    def test_prune_history_deletes_expired_files(self):
        reference = datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.mkdir(exist_ok=True)
            old = root / "old.json"
            recent = root / "recent.json"
            old.write_text("{}", encoding="utf-8")
            recent.write_text("{}", encoding="utf-8")
            old_time = (reference - timedelta(days=31)).timestamp()
            recent_time = (reference - timedelta(days=1)).timestamp()
            os.utime(old, (old_time, old_time))
            os.utime(recent, (recent_time, recent_time))

            deleted = history.prune_history(root, retention_days=30, reference=reference)

            self.assertFalse(old.exists())
            self.assertTrue(recent.exists())

        self.assertEqual(deleted, 1)

    def test_capture_extracts_last_json_object_from_mixed_output(self):
        text = (
            "log before\n{\"first\": true}\nmore logs\n"
            "{\"task_type\": \"daily_inspection\", \"job_id\": \"job-1\", "
            "\"status\": \"success\", \"checks\": {\"sts\": {\"ok\": true}}}\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "stdout.log"
            output = root / "result.json"
            source.write_text(text, encoding="utf-8")

            response = history.capture_result_file(source, output, 4096)
            stored = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(response["captured"])
        self.assertEqual(stored["task_type"], "daily_inspection")
        self.assertEqual(stored["job_id"], "job-1")

    def test_history_compacts_check_details(self):
        record = history.build_history_record(
            {
                "task_type": "alert_analysis",
                "job_id": "job",
                "checks": {
                    "sts": {
                        "ok": True,
                        "account": "000000000000",
                        "arn": "arn:aws:sts::000000000000:assumed-role/example",
                        "user_id": "sensitive-session-id",
                    },
                    "logs": {
                        "ok": True,
                        "event_count": 2,
                        "events": ["raw log one", "raw log two"],
                    },
                },
            },
            exit_code=0,
        )
        serialized = json.dumps(record)
        self.assertNotIn("assumed-role", serialized)
        self.assertNotIn("sensitive-session-id", serialized)
        self.assertNotIn("raw log one", serialized)
        self.assertEqual(record["checks"]["logs"]["event_count"], 2)

    def test_environment_aggregate_uses_configured_limits(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "OPENCLAW_EFS_HISTORY_DIR": directory,
                "OPENCLAW_EFS_HISTORY_TASK_TYPES": "alert_analysis",
                "OPENCLAW_REPORT_EFS_LOOKBACK_HOURS": "24",
                "OPENCLAW_REPORT_EFS_MAX_ITEMS": "5",
                "OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES": "4096",
            },
            clear=False,
        ):
            response = history.recent_history_from_environment()

        self.assertEqual(response["lookback_hours"], 24)
        self.assertEqual(response["max_items"], 5)
        self.assertEqual(response["task_types"], ["alert_analysis"])


if __name__ == "__main__":
    unittest.main()
