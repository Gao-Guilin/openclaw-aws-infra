from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
from typing import Any


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "_shared"
    / "job_status_store.py"
)

SPEC = importlib.util.spec_from_file_location(
    "job_status_store",
    MODULE_PATH,
)

assert SPEC is not None
assert SPEC.loader is not None

job_status_store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(job_status_store)


class FakeDynamoDBClient:
    def __init__(
        self,
        exists: bool = True,
        status: str | None = "DISPATCHING",
    ) -> None:
        self.exists = exists
        self.status = status
        self.update_requests: list[dict[str, Any]] = []

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        if not self.exists:
            return {}

        item: dict[str, Any] = {
            "job_id": {"S": "job-123"},
        }

        if self.status is not None:
            item["status"] = {"S": self.status}

        return {"Item": item}

    def update_item(self, **kwargs: Any) -> dict[str, Any]:
        self.update_requests.append(kwargs)
        return {
            "Attributes": {
                "job_id": {"S": "job-123"},
            }
        }


def test_target_status() -> None:
    assert job_status_store.target_status(0) == "SUCCEEDED"
    assert job_status_store.target_status(1) == "FAILED"
    assert job_status_store.target_status(137) == "FAILED"


def test_missing_job_is_skipped() -> None:
    client = FakeDynamoDBClient(exists=False)

    result = job_status_store.mark_running(
        client=client,
        table_name="jobs-table",
        job_id="missing-job",
        now="2026-08-02T00:00:00Z",
    )

    assert result["ok"] is True
    assert result["updated"] is False
    assert result["reason"] == "job_not_found"
    assert client.update_requests == []


def test_running_update_sets_started_at_and_status() -> None:
    client = FakeDynamoDBClient(status="DISPATCHING")

    result = job_status_store.mark_running(
        client=client,
        table_name="jobs-table",
        job_id="job-123",
        now="2026-08-02T00:00:00Z",
    )

    assert result["ok"] is True
    assert result["updated"] is True

    request = client.update_requests[0]

    assert "#job_status = :running" in request["UpdateExpression"]
    assert "started_at = if_not_exists" in request["UpdateExpression"]
    assert request["ExpressionAttributeValues"][":running"] == {
        "S": "RUNNING"
    }


def test_success_update_sets_terminal_fields_and_hash(
    tmp_path: Path,
) -> None:
    result_path = tmp_path / "result.json"
    result_path.write_text(
        json.dumps({
            "status": "success",
            "overall_ok": True,
        }),
        encoding="utf-8",
    )

    expected_hash = hashlib.sha256(result_path.read_bytes()).hexdigest()

    client = FakeDynamoDBClient(status="RUNNING")

    result = job_status_store.mark_finished(
        client=client,
        table_name="jobs-table",
        job_id="job-123",
        exit_code=0,
        result_file=str(result_path),
        now="2026-08-02T00:01:00Z",
    )

    assert result["status"] == "SUCCEEDED"

    request = client.update_requests[0]
    values = request["ExpressionAttributeValues"]

    assert values[":requested_status"] == {"S": "SUCCEEDED"}
    assert values[":exit_code"] == {"N": "0"}
    assert values[":result_sha256"] == {"S": expected_hash}
    assert values[":result_status"] == {"S": "success"}
    assert values[":result_overall_ok"] == {"BOOL": True}
    assert "REMOVE error_message" in request["UpdateExpression"]


def test_failure_update_sets_error_and_stage() -> None:
    client = FakeDynamoDBClient(status="RUNNING")

    result = job_status_store.mark_finished(
        client=client,
        table_name="jobs-table",
        job_id="job-123",
        exit_code=17,
        error_message="skill execution failed",
        failure_stage="skill",
        now="2026-08-02T00:01:00Z",
    )

    assert result["status"] == "FAILED"

    request = client.update_requests[0]
    values = request["ExpressionAttributeValues"]

    assert values[":requested_status"] == {"S": "FAILED"}
    assert values[":exit_code"] == {"N": "17"}
    assert values[":error_message"] == {
        "S": "skill execution failed"
    }
    assert values[":failure_stage"] == {"S": "skill"}


def test_terminal_status_cannot_return_to_running() -> None:
    client = FakeDynamoDBClient(status="SUCCEEDED")

    result = job_status_store.mark_running(
        client=client,
        table_name="jobs-table",
        job_id="job-123",
    )

    assert result["ok"] is False
    assert result["reason"] == "terminal_status_conflict"
    assert result["current_status"] == "SUCCEEDED"
    assert client.update_requests == []


def test_opposite_terminal_status_is_not_overwritten() -> None:
    client = FakeDynamoDBClient(status="SUCCEEDED")

    result = job_status_store.mark_finished(
        client=client,
        table_name="jobs-table",
        job_id="job-123",
        exit_code=1,
    )

    assert result["ok"] is False
    assert result["reason"] == "terminal_status_conflict"
    assert result["current_status"] == "SUCCEEDED"
    assert result["requested_status"] == "FAILED"
    assert client.update_requests == []
