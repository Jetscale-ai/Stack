from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional


@dataclass(frozen=True)
class Ctx:
    mode: str  # plan|apply|verify
    env_id: str
    region: str
    expected_account_id: str


@dataclass(frozen=True)
class ActionRecord:
    desc: str
    mode: str  # plan|apply
    ok: bool
    rc: Optional[int] = None
    stderr: str = ""


@dataclass
class Summary:
    initial_tagged: List[str] = field(default_factory=list)
    final_tagged: List[str] = field(default_factory=list)
    final_existing: List[str] = field(default_factory=list)
    final_stale: List[str] = field(default_factory=list)
    final_unknown: List[str] = field(default_factory=list)
    # Resources that still show up in reads but are demonstrably in a deletion lifecycle
    # (AWS eventual consistency / async delete). These should not fail the run.
    final_eventual: List[str] = field(default_factory=list)
    actions: List[ActionRecord] = field(default_factory=list)

    def add_action(self, rec: ActionRecord) -> None:
        self.actions.append(rec)

    def failed_actions(self) -> List[ActionRecord]:
        return [a for a in self.actions if not a.ok and a.mode == "apply"]
