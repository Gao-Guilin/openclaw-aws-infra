from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace

os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("JOBS_TABLE_NAME", "jobs")
os.environ.setdefault("STATE_MACHINE_ARN", "arn:aws:states:ap-northeast-1:123456789012:stateMachine:test")
os.environ.setdefault("OPENCLAW_ENVIRONMENT", "test")

MAIN_TF = Path(__file__).resolve().parents[1] / "main.tf"
text = MAIN_TF.read_text(encoding="utf-8")
match = __import__("re").search(r'source_content\s*=\s*<<-PY\n(.*?)\n  PY', text, __import__("re").S)
assert match, "job_receiver.py heredoc was not found in main.tf"
_TEMP_SOURCE_DIR = tempfile.TemporaryDirectory()
SOURCE = Path(_TEMP_SOURCE_DIR.name) / "job_receiver.py"
SOURCE.write_text(match.group(1), encoding="utf-8")
spec = importlib.util.spec_from_file_location("job_receiver_under_test", SOURCE)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


class FakeTable:
    def __init__(self):
        self.items = {}

    def put_item(self, Item, ConditionExpression=None):
        if Item["job_id"] in self.items:
            error = {"Error": {"Code": "ConditionalCheckFailedException"}}
            raise module.ClientError(error, "PutItem")
        self.items[Item["job_id"]] = dict(Item)
        return {}

    def get_item(self, Key, ConsistentRead=False):
        item = self.items.get(Key["job_id"])
        return {"Item": dict(item)} if item else {}

    def update_item(self, Key, ExpressionAttributeValues, **kwargs):
        item = self.items[Key["job_id"]]
        if ":status" in ExpressionAttributeValues:
            item["status"] = ExpressionAttributeValues[":status"]
        if ":execution_arn" in ExpressionAttributeValues:
            item["execution_arn"] = ExpressionAttributeValues[":execution_arn"]
        if ":updated_at" in ExpressionAttributeValues:
            item["updated_at"] = ExpressionAttributeValues[":updated_at"]
        if ":failure_stage" in ExpressionAttributeValues:
            item["failure_stage"] = ExpressionAttributeValues[":failure_stage"]
        if ":error_message" in ExpressionAttributeValues:
            item["error_message"] = ExpressionAttributeValues[":error_message"]
        return {}


class FakeStepFunctions:
    def __init__(self):
        self.executions = []

    def start_execution(self, **kwargs):
        self.executions.append(kwargs)
        return {"executionArn": f"arn:execution:{kwargs['name']}"}


def setup_function():
    module.JOBS_TABLE = FakeTable()
    module.STEP_FUNCTIONS = FakeStepFunctions()


def test_api_healthcheck_creates_lifecycle_record():
    event = {
        "requestContext": {"requestId": "req-1"},
        "body": json.dumps({
            "task_type": "healthcheck",
            "priority": "medium",
            "target": "aws-account",
        }),
    }
    response = module.lambda_handler(event, SimpleNamespace(aws_request_id="lambda-1"))
    assert response["statusCode"] == 202
    body = json.loads(response["body"])
    assert module.JOBS_TABLE.items[body["job_id"]]["status"] == "DISPATCHING"
    workflow = json.loads(module.STEP_FUNCTIONS.executions[0]["input"])
    assert workflow["alert_json"] == "{}"


def test_api_alert_requires_payload():
    event = {
        "requestContext": {"requestId": "req-2"},
        "body": json.dumps({
            "task_type": "alert_analysis",
            "priority": "high",
            "target": "aws-account",
        }),
    }
    response = module.lambda_handler(event, SimpleNamespace(aws_request_id="lambda-2"))
    assert response["statusCode"] == 400


def test_scheduler_event_creates_job_before_workflow():
    event = {
        "event_type": "scheduled-job",
        "execution_id": "execution-123",
        "schedule_name": "openclaw-aws-test-morning-inspection",
        "scheduled_time": "2026-08-04T01:00:00Z",
        "task_type": "daily_inspection",
        "priority": "medium",
        "target": "aws-account",
    }
    result = module.lambda_handler(event, SimpleNamespace())
    assert result["status"] == "DISPATCHING"
    item = module.JOBS_TABLE.items[result["job_id"]]
    assert item["source"] == "scheduler"
    assert item["schedule_name"].endswith("morning-inspection")


def test_cloudwatch_alarm_becomes_alert_job():
    event = {
        "version": "0",
        "id": "alarm-event-1",
        "detail-type": "CloudWatch Alarm State Change",
        "source": "aws.cloudwatch",
        "time": "2026-08-04T01:00:00Z",
        "detail": {
            "alarmName": "openclaw-aws-test-job-receiver-errors",
            "state": {"value": "ALARM", "reason": "controlled test"},
        },
    }
    result = module.lambda_handler(event, SimpleNamespace())
    workflow = json.loads(module.STEP_FUNCTIONS.executions[0]["input"])
    assert workflow["task_type"] == "alert_analysis"
    alert_payload = json.loads(workflow["alert_json"])
    assert alert_payload["id"] == "alarm-event-1"
    assert alert_payload["detail"]["alarmName"].endswith("errors")
    assert "configuration" not in alert_payload["detail"]
    assert module.JOBS_TABLE.items[result["job_id"]]["alarm_name"].endswith("errors")


def test_api_alert_rejects_oversized_payload_before_workflow():
    event = {
        "requestContext": {"requestId": "req-large-alert"},
        "body": json.dumps({
            "task_type": "alert_analysis",
            "priority": "high",
            "target": "aws-account",
            "alert_payload": {"message": "x" * (module.MAX_ALERT_JSON_BYTES + 1)},
        }),
    }
    response = module.lambda_handler(event, SimpleNamespace(aws_request_id="lambda-large-alert"))
    assert response["statusCode"] == 400
    assert module.STEP_FUNCTIONS.executions == []


def test_scheduler_retry_recovers_start_failed_record():
    event = {
        "event_type": "scheduled-job",
        "execution_id": "execution-retry-1",
        "schedule_name": "openclaw-aws-test-morning-inspection",
        "scheduled_time": "2026-08-04T02:00:00Z",
        "task_type": "daily_inspection",
        "priority": "medium",
        "target": "aws-account",
    }
    normalized = module._normalize_scheduler_event(event)
    job_id = module._job_id_for(normalized)
    module.JOBS_TABLE.items[job_id] = {
        "job_id": job_id,
        "status": "START_FAILED",
        "requested_at": event["scheduled_time"],
    }
    result = module.lambda_handler(event, SimpleNamespace())
    assert result["status"] == "DISPATCHING"
    assert result["duplicate"] is True
    assert module.JOBS_TABLE.items[job_id]["status"] == "DISPATCHING"
    assert len(module.STEP_FUNCTIONS.executions) == 1
