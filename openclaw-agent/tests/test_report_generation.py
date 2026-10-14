import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import boto3
from botocore.stub import ANY, Stubber


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "aws-report-generation"
    / "report_generation.py"
)
SPEC = importlib.util.spec_from_file_location("openclaw_report_generation", MODULE_PATH)
report = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(report)

SUMMARIZER_PATH = MODULE_PATH.parent / "report_summarizer.py"
SUMMARIZER_SPEC = importlib.util.spec_from_file_location("openclaw_report_summarizer", SUMMARIZER_PATH)
summarizer = importlib.util.module_from_spec(SUMMARIZER_SPEC)
assert SUMMARIZER_SPEC and SUMMARIZER_SPEC.loader
SUMMARIZER_SPEC.loader.exec_module(summarizer)


class ReportGenerationTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(
            os.environ,
            {
                "AWS_EC2_METADATA_DISABLED": "true",
                "AWS_REGION": "ap-northeast-1",
                "OPENCLAW_ENVIRONMENT": "dev",
                "DEEPSEEK_API_KEY": "",
            },
            clear=False,
        )
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_report_id_is_deterministic(self):
        payload = {"task_type": "alert_analysis", "overall_ok": True}
        first = report.build_report_id(payload, "alert_analysis", "job-1")
        second = report.build_report_id(payload, "alert_analysis", "job-1")
        self.assertEqual(first, second)
        self.assertRegex(first, r"^report-[0-9a-f]{32}$")

    def test_artifact_name_contains_skill_time_and_job(self):
        payload = {
            "task_type": "healthcheck",
            "selected_skill": "aws-task-healthcheck",
            "timestamp_utc": "2026-10-13T03:15:22+00:00",
        }
        name = report.build_artifact_basename(payload, "healthcheck", "job-123", "2026-10-13T04:00:00+00:00")
        self.assertEqual(name, "aws-task-healthcheck_20261013T031522Z_job-123")

    def test_s3_locations_include_environment_skill_and_date(self):
        payload = {"timestamp_utc": "2026-10-13T03:15:22+00:00"}
        locations = report.build_s3_locations(
            "bucket-name",
            "reports",
            "dev",
            "aws-task-healthcheck",
            "aws-task-healthcheck_20261013T031522Z_job-123",
            payload,
            "2026-10-13T04:00:00+00:00",
        )
        self.assertEqual(
            locations["markdown_uri"],
            "s3://bucket-name/reports/dev/aws-task-healthcheck/2026/10/13/"
            "aws-task-healthcheck_20261013T031522Z_job-123.md",
        )
        self.assertTrue(locations["summary_key"].endswith(".summary.json"))

    def test_clean_healthcheck_uses_template(self):
        payload = {
            "task_type": "healthcheck",
            "overall_ok": True,
            "warnings": [],
            "checks": {
                "openclaw_cli": {"ok": True},
                "sts_get_caller_identity": {"ok": True},
            },
        }
        self.assertEqual(report.select_summary_route(payload, "healthcheck"), "template")
        presentation = report.build_presentation(payload, "healthcheck")
        self.assertEqual(presentation["summary_mode"], "template")
        self.assertIn("总体结果正常", presentation["executive_summary"])

    def test_healthcheck_warning_routes_to_flash_then_falls_back_without_key(self):
        payload = {
            "task_type": "healthcheck",
            "overall_ok": True,
            "warnings": ["demo warning"],
            "checks": {"openclaw_cli": {"ok": True}},
        }
        self.assertEqual(report.select_summary_route(payload, "healthcheck"), "llm_flash")
        presentation = report.build_presentation(payload, "healthcheck")
        self.assertEqual(presentation["summary_mode"], "fallback_template")
        self.assertIn("DEEPSEEK_API_KEY", presentation["llm_error"])

    def test_high_alert_routes_to_pro(self):
        payload = {
            "task_type": "alert_analysis",
            "overall_ok": True,
            "severity": "high",
            "checks": {},
            "warnings": [],
        }
        self.assertEqual(report.select_summary_route(payload, "alert_analysis"), "llm_pro")

    def test_complex_cost_routes_to_pro(self):
        payload = {
            "task_type": "cost_inspection",
            "overall_ok": True,
            "checks": {},
            "cost_risks": ["a", "b", "c"],
            "permission_limitations": [],
        }
        self.assertEqual(report.select_summary_route(payload, "cost_inspection"), "llm_pro")

    def test_llm_output_is_used_only_for_presentation_fields(self):
        payload = {
            "task_type": "alert_analysis",
            "overall_ok": True,
            "severity": "medium",
            "confirmed_facts": ["fact-1"],
            "checks": {},
        }
        with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "dummy"}, clear=False), patch.object(
            report,
            "summarize_with_openclaw",
            return_value={
                "executive_summary": "中文摘要",
                "risk_explanation": "中文风险说明",
                "recommended_actions": ["人工检查日志"],
                "model_used": "deepseek/deepseek-v4-flash",
                "provider": "deepseek",
            },
        ):
            presentation = report.build_presentation(payload, "alert_analysis")
        self.assertEqual(presentation["summary_mode"], "llm_flash")
        self.assertEqual(presentation["executive_summary"], "中文摘要")
        self.assertEqual(payload["severity"], "medium")
        self.assertEqual(payload["confirmed_facts"], ["fact-1"])

    def test_markdown_is_fixed_chinese_structure(self):
        payload = {
            "task_type": "healthcheck",
            "job_id": "job-1",
            "timestamp_utc": "2026-10-13T03:15:22+00:00",
            "overall_ok": True,
            "checks": {
                "openclaw_cli": {"ok": True},
                "sts_get_caller_identity": {"ok": True, "account": "123"},
            },
        }
        presentation = report.build_template_presentation(payload, "healthcheck")
        presentation.update({"summary_mode": "template", "model_used": None, "llm_error": None})
        markdown = report.build_markdown(
            payload,
            "OPENCLAW_REPORT_INPUT_FILE",
            "healthcheck",
            "aws-task-healthcheck",
            "job-1",
            "report-1",
            "ap-northeast-1",
            "dev",
            "2026-10-13T03:16:00+00:00",
            "generated",
            presentation,
            [],
            [],
            [],
            [],
            payload["checks"],
        )
        for heading in (
            "## 一、检查结论",
            "## 二、本次检查内容",
            "## 三、检查结果",
            "## 四、发现的问题、警告与限制",
            "## 五、风险说明",
            "## 六、建议",
            "## 七、任务信息",
            "## 八、结构化证据摘要",
        ):
            self.assertIn(heading, markdown)
        self.assertIn("OpenClaw CLI", markdown)
        self.assertIn("AWS STS 身份认证", markdown)

    def test_put_s3_object(self):
        client = boto3.client(
            "s3",
            region_name="ap-northeast-1",
            aws_access_key_id="test",
            aws_secret_access_key="test",
            aws_session_token="test",
        )
        with Stubber(client) as stubber:
            stubber.add_response(
                "put_object",
                {"ETag": '"etag"'},
                {
                    "Bucket": "reports-bucket",
                    "Key": "reports/demo.md",
                    "Body": b"hello",
                    "ContentType": "text/markdown",
                },
            )
            result = report.put_s3_object(
                "ap-northeast-1",
                "reports-bucket",
                "reports/demo.md",
                b"hello",
                "text/markdown",
                client=client,
            )
        self.assertTrue(result["ok"])

    def test_write_report_index(self):
        client = boto3.client(
            "dynamodb",
            region_name="ap-northeast-1",
            aws_access_key_id="test",
            aws_secret_access_key="test",
            aws_session_token="test",
        )
        summary = {
            "report_id": "report-123",
            "job_id": "job-123",
            "task_type": "report_generation",
            "source_task_type": "alert_analysis",
            "source_skill": "aws-alert-analysis",
            "source_overall_ok": True,
            "status": "success",
            "report_status": "generated",
            "summary_mode": "template",
            "timestamp_utc": "2026-10-13T00:00:00+00:00",
            "markdown_sha256": "0" * 64,
            "warning_count": 0,
            "failure_count": 0,
            "cost_risk_count": 0,
            "artifacts": {"s3": {"markdown_uri": "s3://bucket/report.md", "summary_uri": "s3://bucket/report.json"}},
        }
        with Stubber(client) as stubber:
            stubber.add_response("put_item", {}, {"TableName": "reports-table", "Item": ANY})
            result = report.write_report_index("ap-northeast-1", "reports-table", summary, client=client)
        self.assertTrue(result["ok"])

    def test_main_writes_chinese_template_and_final_summary(self):
        payload = {
            "task_type": "healthcheck",
            "job_id": "job-main-test",
            "selected_skill": "aws-task-healthcheck",
            "timestamp_utc": "2026-10-13T03:15:22+00:00",
            "aws_region": "ap-northeast-1",
            "overall_ok": True,
            "warnings": [],
            "checks": {"openclaw_cli": {"ok": True}},
            "authorization": "Bearer should-not-leak",
        }
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "OPENCLAW_REPORT_INPUT_JSON": json.dumps(payload),
                "OPENCLAW_REPORT_INPUT_FILE": "",
                "OPENCLAW_SOURCE_TASK_TYPE": "healthcheck",
                "OPENCLAW_SOURCE_SKILL": "aws-task-healthcheck",
                "OPENCLAW_REPORT_REQUIRE_INPUT": "true",
                "OPENCLAW_REPORT_UPLOAD_S3": "false",
                "OPENCLAW_REPORT_WRITE_INDEX": "false",
                "OPENCLAW_REPORT_DIR": directory,
                "OPENCLAW_JOB_ID": "job-main-test",
                "OPENCLAW_REPORT_SUMMARY_MODE": "auto",
            },
            clear=False,
        ), patch.object(
            report,
            "check_sts",
            return_value={"ok": True, "account": "000000000000", "arn": "arn:test"},
        ):
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                rc = report.main()
            output = json.loads(stdout.getvalue())
            markdown_path = Path(output["artifacts"]["local"]["markdown"]["path"])
            summary_path = Path(output["artifacts"]["local"]["summary"]["path"])
            markdown = markdown_path.read_text(encoding="utf-8")
            stored = json.loads(summary_path.read_text(encoding="utf-8"))

        self.assertEqual(rc, 0)
        self.assertTrue(output["overall_ok"])
        self.assertTrue(output["source_overall_ok"])
        self.assertEqual(output["summary_mode"], "template")
        self.assertEqual(stored, output)
        self.assertIn("健康检查报告", markdown)
        self.assertNotIn("should-not-leak", json.dumps(output))
        self.assertNotIn("should-not-leak", markdown)
        self.assertIn("aws-task-healthcheck_20261013T031522Z_job-main-test", markdown_path.name)

    def test_main_runs_requested_s3_and_index_operations(self):
        payload = {
            "task_type": "healthcheck",
            "selected_skill": "aws-task-healthcheck",
            "timestamp_utc": "2026-10-13T03:15:22+00:00",
            "overall_ok": True,
            "warnings": [],
            "checks": {"demo": {"ok": True}},
        }
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "OPENCLAW_REPORT_INPUT_JSON": json.dumps(payload),
                "OPENCLAW_REPORT_INPUT_FILE": "",
                "OPENCLAW_SOURCE_TASK_TYPE": "healthcheck",
                "OPENCLAW_SOURCE_SKILL": "aws-task-healthcheck",
                "OPENCLAW_REPORT_REQUIRE_INPUT": "true",
                "OPENCLAW_REPORT_UPLOAD_S3": "true",
                "OPENCLAW_REPORT_WRITE_INDEX": "true",
                "OPENCLAW_REPORT_DIR": directory,
                "OPENCLAW_JOB_ID": "job-aws-write-test",
                "S3_REPORT_BUCKET": "reports-bucket",
                "DYNAMODB_REPORTS_TABLE": "reports-table",
                "OPENCLAW_REPORT_SUMMARY_MODE": "template",
            },
            clear=False,
        ), patch.object(
            report, "check_sts", return_value={"ok": True, "account": "000000000000"}
        ), patch.object(
            report, "put_s3_object", return_value={"ok": True, "etag": "etag"}
        ) as put_s3, patch.object(
            report,
            "write_report_index",
            return_value={"ok": True, "enabled": True, "table_name": "reports-table", "report_id": "stored"},
        ) as put_index:
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                rc = report.main()
            output = json.loads(stdout.getvalue())

        self.assertEqual(rc, 0)
        self.assertTrue(output["overall_ok"])
        self.assertEqual(put_s3.call_count, 3)
        put_index.assert_called_once()
        self.assertTrue(output["artifacts"]["s3"]["ok"])
        self.assertIn("/dev/aws-task-healthcheck/2026/10/13/", output["artifacts"]["s3"]["markdown_key"])

    def test_main_rejects_missing_input_by_default(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "OPENCLAW_REPORT_INPUT_JSON": "",
                "OPENCLAW_REPORT_INPUT_FILE": "",
                "OPENCLAW_REPORT_EFS_AGGREGATE": "false",
                "OPENCLAW_REPORT_REQUIRE_INPUT": "true",
                "OPENCLAW_REPORT_UPLOAD_S3": "false",
                "OPENCLAW_REPORT_WRITE_INDEX": "false",
                "OPENCLAW_REPORT_DIR": directory,
                "OPENCLAW_REPORT_SUMMARY_MODE": "template",
            },
            clear=False,
        ), patch.object(report, "check_sts", return_value={"ok": True}):
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                rc = report.main()
            output = json.loads(stdout.getvalue())

        self.assertEqual(rc, 1)
        self.assertFalse(output["overall_ok"])
        self.assertIn("report_input_required", {item["code"] for item in output["errors"]})

    def test_explicit_report_input_precedes_efs_history(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "OPENCLAW_REPORT_INPUT_JSON": json.dumps({"task_type": "alert_analysis", "overall_ok": True}),
                "OPENCLAW_REPORT_INPUT_FILE": "",
                "OPENCLAW_REPORT_EFS_AGGREGATE": "true",
                "OPENCLAW_EFS_HISTORY_DIR": directory,
            },
            clear=False,
        ):
            result = report.load_input_payload()
        self.assertEqual(result["source"], "OPENCLAW_REPORT_INPUT_JSON")


class ReportSummarizerTests(unittest.TestCase):
    def test_parse_model_output_accepts_plain_json(self):
        result = summarizer.parse_model_output(
            json.dumps(
                {
                    "executive_summary": "系统总体正常。",
                    "risk_explanation": "当前未发现明显风险。",
                    "recommended_actions": ["继续监控。"],
                },
                ensure_ascii=False,
            )
        )
        self.assertEqual(result["recommended_actions"], ["继续监控。"])

    def test_parse_model_output_accepts_json_fence(self):
        result = summarizer.parse_model_output(
            '```json\n{"executive_summary":"摘要","risk_explanation":"风险","recommended_actions":[]}\n```'
        )
        self.assertEqual(result["executive_summary"], "摘要")

    def test_model_payload_excludes_raw_alert_payload(self):
        payload = {
            "task_type": "alert_analysis",
            "sanitized_alert_payload": {"large": "raw"},
            "confirmed_facts": ["fact"],
            "likely_causes": ["hypothesis"],
        }
        model_payload = summarizer.build_model_payload(payload, "alert_analysis")
        self.assertNotIn("sanitized_alert_payload", model_payload)
        self.assertEqual(model_payload["confirmed_facts"], ["fact"])


if __name__ == "__main__":
    unittest.main()
