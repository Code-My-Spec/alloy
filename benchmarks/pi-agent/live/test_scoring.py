import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('live_run', Path(__file__).with_name('run.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ScoringTests(unittest.TestCase):
    def result(self):
        return {'status': 'ok', 'text': '{"total": 42}', 'tool_errors': 0,
                'calls': [{'name': 'lookup', 'args': {'key': 'A'}, 'result': {'value': 6}},
                          {'name': 'calculate', 'args': {'op': 'multiply', 'a': 6, 'b': 7}, 'result': {'value': 42}},
                          {'name': 'submit_answer', 'args': {'answer': {'total': 42}}, 'result': {'total': 42}}]}

    def test_correct_answer_and_clean_actions(self):
        self.assertTrue(module.score(self.result(), {'total': 42})['success'])

    def test_wrong_final_extra_fields_and_non_json_fail(self):
        for text in ['{"total": 41}', '{"total": 42, "extra": 1}', '```json\n{"total":42}\n```', '']:
            result = self.result(); result['text'] = text
            self.assertFalse(module.score(result, {'total': 42})['success'])

    def test_failure_cannot_pass_with_correct_text(self):
        result = self.result(); result['status'] = 'error'
        self.assertFalse(module.score(result, {'total': 42})['success'])

    def test_wrong_or_duplicate_submission_fails(self):
        result = self.result()
        result['calls'].append({'name': 'submit_answer', 'args': {'answer': {'total': 41}}, 'result': {}})
        score = module.score(result, {'total': 42})
        self.assertFalse(score['success']); self.assertEqual(score['wrong_submissions'], 1)

    def test_missing_grounding_fails(self):
        result = self.result(); result['calls'] = result['calls'][-1:]
        self.assertFalse(module.score(result, {'total': 42})['success'])

    def test_recovered_tool_error_is_separate_from_final_correctness(self):
        result = self.result(); result['tool_errors'] = 1
        score = module.score(result, {'total': 42})
        self.assertTrue(score['final_correct']); self.assertFalse(score['success'])

    def test_sse_usage_and_standard_price(self):
        raw = b'data: {"usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":100,"thoughtsTokenCount":10,"cachedContentTokenCount":200},"modelVersion":"pinned"}\r\n\r\n'
        usage, version = module.usage_of(raw)
        self.assertEqual(version, 'pinned')
        self.assertAlmostEqual(module.estimate(usage), .000521)


if __name__ == '__main__':
    unittest.main()
