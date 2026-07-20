#!/usr/bin/env python3
"""queue_state_machine.py — headless proof of the handoff-121 job QUEUE state
machine, independent of Xcode, subprocesses, and the network.

It drives the real `Scheduler` with an INJECTED launcher (no solve is spawned), so
promotion, queue position, queued-cancel, and completion-promotes are exercised
deterministically. The scheduler is the correctness core of "a second submitted
job queues instead of spawning a competing solver" — solves are memory-bandwidth-
bound (handoff 113), so parallel jobs run slower than sequential; queueing is
faster, not merely tidier.

Run:  python3 queue_state_machine.py         (unittest; exit 0 = pass)
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import topopt_worker as w  # noqa: E402


def make_job(job_id, project=None):
    return w.Job(job_id, tmpdir="/tmp/none", out_dir="/tmp/none/out",
                 cmd=["true"], project_name=project)


class RecordingLauncher:
    """A launcher that records promotions instead of spawning a solve, so the test
    controls exactly when a running job 'finishes'."""

    def __init__(self):
        self.started = []

    def __call__(self, job):
        self.started.append(job.id)


class QueueStateMachineTests(unittest.TestCase):

    def setUp(self):
        self.launcher = RecordingLauncher()
        self.sched = w.Scheduler(max_concurrency=1, launcher=self.launcher)
        # The Scheduler under test is the module SCHED so Job.emit's terminal path
        # (which never calls the scheduler) and any position lookups line up; the
        # webhook is inert (CFG is None) so terminal events are side-effect-free.
        w.SCHED = self.sched
        w.CFG = None

    def _finish(self, job, state="done"):
        """Simulate a running job reaching a terminal state, exactly as
        run_job_thread would: post the terminal event, then free the slot."""
        job.emit({"type": state, "artifacts": []})
        self.sched.on_finished(job)

    # -- submit x2 -> one running, one queued --------------------------------

    def test_second_submit_queues_not_parallel(self):
        a, b = make_job("A", "Alpha"), make_job("B", "Beta")
        self.sched.submit(a)
        self.sched.submit(b)

        self.assertEqual(a.state, "running", "first job runs immediately")
        self.assertEqual(b.state, "queued", "second job QUEUES (not a parallel solve)")
        self.assertEqual(self.sched.position("B"), 1, "queued behind the one running job")
        self.assertEqual(self.launcher.started, ["A"], "only ONE solve was launched")

        rows, summary = self.sched.list_snapshots()
        self.assertEqual(summary["running"], 1)
        self.assertEqual(summary["queued"], 1)
        self.assertEqual(summary["max_concurrency"], 1)
        by_id = {r["id"]: r for r in rows}
        self.assertEqual(by_id["A"]["state"], "running")
        self.assertIsNone(by_id["A"]["position"])
        self.assertEqual(by_id["B"]["state"], "queued")
        self.assertEqual(by_id["B"]["position"], 1)

    def test_lone_job_gets_no_queued_event(self):
        """The single-job protocol is byte-identical: a job that starts immediately
        emits NO `queued` event."""
        a = make_job("A")
        self.sched.submit(a)
        self.assertFalse(any(e["type"] == "queued" for e in a.events),
                         "a job that runs immediately must not emit a queued event")

    def test_queued_job_emits_queued_event_immediately(self):
        a, b = make_job("A"), make_job("B")
        self.sched.submit(a)
        self.sched.submit(b)
        queued = [e for e in b.events if e["type"] == "queued"]
        self.assertEqual(len(queued), 1, "a job that has to wait emits ONE queued event")
        self.assertEqual(queued[0]["position"], 1, "the queued event carries its position")

    # -- cancel a QUEUED job -------------------------------------------------

    def test_cancel_queued_job_dequeues_without_killing(self):
        a, b, c = make_job("A"), make_job("B"), make_job("C")
        for j in (a, b, c):
            self.sched.submit(j)
        # A running, B pos1, C pos2.
        self.assertEqual(self.sched.position("B"), 1)
        self.assertEqual(self.sched.position("C"), 2)

        result = self.sched.cancel(b)
        self.assertEqual(result, "dequeued", "a queued cancel dequeues (no process to kill)")
        self.assertEqual(b.state, "cancelled")
        self.assertTrue(b.done)
        self.assertEqual(a.state, "running", "cancelling a queued job never touches the runner")
        self.assertEqual(self.sched.position("C"), 1, "C moves up when B leaves the queue")
        self.assertEqual(self.launcher.started, ["A"], "no new solve launched by a queued cancel")

    # -- completion promotes the next queued job -----------------------------

    def test_completion_promotes_next(self):
        a, b = make_job("A"), make_job("B")
        self.sched.submit(a)
        self.sched.submit(b)
        self.assertEqual(b.state, "queued")

        self._finish(a, "done")
        self.assertEqual(a.state, "done")
        self.assertEqual(b.state, "running", "finishing the running job promotes the queued one")
        self.assertEqual(self.launcher.started, ["A", "B"], "B launched exactly once, after A")
        self.assertIsNone(self.sched.position("B"), "a running job has no queue position")

    def test_full_scenario_the_incident(self):
        """The exact scenario in the task: submit two, the second queues, the first
        completes, the second starts automatically."""
        first = make_job("first", "Balanced")
        second = make_job("second", "Fine")
        self.sched.submit(first)
        self.sched.submit(second)
        self.assertEqual((first.state, second.state), ("running", "queued"))

        self._finish(first, "done")
        self.assertEqual(second.state, "running",
                         "the second job starts automatically when the first completes")

    def test_cancel_then_complete_promotes_survivor(self):
        a, b, c = make_job("A"), make_job("B"), make_job("C")
        for j in (a, b, c):
            self.sched.submit(j)
        self.sched.cancel(b)                 # dequeue the middle queued job
        self._finish(a, "done")              # finish the runner
        self.assertEqual(c.state, "running", "the surviving queued job is promoted")
        self.assertEqual(b.state, "cancelled")

    # -- reorder: move a queued job to the front -----------------------------

    def test_move_to_front(self):
        a, b, c = make_job("A"), make_job("B"), make_job("C")
        for j in (a, b, c):
            self.sched.submit(j)
        # A running; queue = [B, C].
        self.assertEqual(self.sched.position("C"), 2)
        moved = self.sched.move_to_front(c)
        self.assertTrue(moved)
        self.assertEqual(self.sched.position("C"), 1, "C jumped to the front")
        self.assertEqual(self.sched.position("B"), 2)
        # Finishing A promotes C (the reordered front), not B.
        self._finish(a, "done")
        self.assertEqual(c.state, "running", "the reordered job runs next")
        self.assertEqual(b.state, "queued")

    def test_move_running_job_is_noop(self):
        a, b = make_job("A"), make_job("B")
        self.sched.submit(a)
        self.sched.submit(b)
        self.assertFalse(self.sched.move_to_front(a),
                         "a running job is never preempted by a reorder")

    # -- higher concurrency is honoured --------------------------------------

    def test_max_concurrency_two_runs_two(self):
        sched = w.Scheduler(max_concurrency=2, launcher=RecordingLauncher())
        w.SCHED = sched
        a, b, c = make_job("A"), make_job("B"), make_job("C")
        for j in (a, b, c):
            sched.submit(j)
        self.assertEqual((a.state, b.state, c.state), ("running", "running", "queued"))
        self.assertEqual(sched.position("C"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
