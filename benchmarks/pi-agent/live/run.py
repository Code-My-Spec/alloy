#!/usr/bin/env python3
"""Paired native-provider evaluation. Synthetic data only; no credentials persisted."""
import collections
import datetime
import hashlib
import http.client
import http.server
import json
import math
import os
import random
import select
import statistics
import subprocess
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MODEL = 'gemini-2.5-flash'
OUT = HERE / os.environ.get('LIVE_OUTPUT', 'results')
KEY = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
RECORDS = {}
LOCK = threading.Lock()
MAX_REQUESTS = 900
MAX_ESTIMATED_USD = 2.0


def usage_of(raw):
    usage, version = {}, None
    for line in raw.decode('utf8').splitlines():
        if line.startswith('data: '):
            try:
                event = json.loads(line[6:])
                usage = event.get('usageMetadata') or usage
                version = event.get('modelVersion') or version
            except json.JSONDecodeError:
                pass
    return usage, version


def estimate(usage):
    cached = usage.get('cachedContentTokenCount', 0)
    return ((usage.get('promptTokenCount', 0)-cached)*.3 + cached*.03 +
            (usage.get('candidatesTokenCount', 0)+usage.get('thoughtsTokenCount', 0))*2.5)/1e6


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        parts = self.path.split('/', 2)
        run_id = parts[1]
        path = '/' + parts[2] if len(parts) == 3 else ''
        if run_id not in RECORDS or not path.startswith(f'/v1beta/models/{MODEL}:streamGenerateContent'):
            self.send_error(403)
            return
        with LOCK:
            previous = [r for rows in RECORDS.values() for r in rows]
            over = len(previous) >= MAX_REQUESTS or sum(estimate(r.get('usage', {})) for r in previous) >= MAX_ESTIMATED_USD
        if over or len(RECORDS[run_id]) >= 8:
            self.send_error(429, 'Benchmark request/cost limit')
            return
        body = self.rfile.read(int(self.headers['Content-Length']))
        request = json.loads(body)
        # Assert equivalent generation settings at the actual HTTP boundary.
        config = request.get('generationConfig', {})
        if config.get('temperature') != 0 or config.get('maxOutputTokens') != 512 or config.get('thinkingConfig', {}).get('thinkingBudget') != 0:
            RECORDS[run_id].append({'rejected_settings': request})
            self.send_error(400, 'Benchmark settings mismatch')
            return
        start = time.perf_counter()
        record = {'request': request, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        with LOCK:
            RECORDS[run_id].append(record)
        conn = http.client.HTTPSConnection('generativelanguage.googleapis.com', timeout=35)
        try:
            conn.request('POST', path, body=json.dumps(request, sort_keys=True, separators=(',', ':')).encode(), headers={'x-goog-api-key': KEY, 'Content-Type': 'application/json'})
            response = conn.getresponse()
            record['http_status'] = response.status
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'text/event-stream'))
            self.send_header('Connection', 'close')
            self.end_headers()
            chunks = []
            while chunk := response.read1(8192):
                if not chunks:
                    record['first_byte_ms'] = (time.perf_counter()-start)*1000
                chunks.append(chunk)
                self.wfile.write(chunk)
                self.wfile.flush()
            raw = b''.join(chunks)
            record['usage'], record['model_version'] = usage_of(raw)
            record['response'] = raw.decode('utf8')
        except Exception as error:
            record['transport_error'] = type(error).__name__
            self.close_connection = True
        finally:
            record['provider_ms'] = (time.perf_counter()-start)*1000
            conn.close()


class Worker:
    def __init__(self, engine):
        args = ['mise', 'exec', '--', 'mix', 'run', 'benchmarks/pi-agent/live/alloy.exs'] if engine == 'alloy' else ['node', 'benchmarks/pi-agent/live/pi.mjs']
        self.log = (OUT / f'{engine}-stderr.log').open('w')
        child_env = dict(os.environ)
        for key in ['GOOGLE_API_KEY', 'GEMINI_API_KEY']: child_env.pop(key, None)
        self.proc = subprocess.Popen(args, cwd=ROOT, env=child_env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=1)
        while (line := self.proc.stdout.readline()).strip() != 'READY':
            if not line:
                raise RuntimeError(f'{engine} failed to initialize; inspect stderr')

    def run(self, payload):
        self.proc.stdin.write(json.dumps(payload)+'\n')
        self.proc.stdin.flush()
        if not select.select([self.proc.stdout], [], [], 140)[0]:
            raise TimeoutError('Worker deadline exceeded')
        line = self.proc.stdout.readline()
        return json.loads(line)

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        self.log.close()


def score(result, expected):
    calls = result.get('calls', [])
    submitted = [c['args'].get('answer') for c in calls if c['name'] == 'submit_answer']
    try:
        final = json.loads(result.get('text') or '')
    except json.JSONDecodeError:
        final = None
    correct = final == expected
    bad_actions = sum(a != expected for a in submitted)
    grounded = any(c['name']=='lookup' for c in calls) and any(c['name']=='calculate' for c in calls)
    tool_errors = result.get('tool_errors', sum('error' in c.get('result', {}) for c in calls))
    return {'success': result.get('status')=='ok' and correct and submitted==[expected] and grounded and tool_errors==0,
            'final_correct': correct, 'wrong_submissions': bad_actions, 'submissions': len(submitted), 'tool_errors': tool_errors, 'used_required_tools': grounded}


def wilson(successes, total):
    z=1.96; p=successes/total;den=1+z*z/total
    center=(p+z*z/(2*total))/den
    delta=z*math.sqrt(p*(1-p)/total+z*z/(4*total*total))/den
    return [center-delta, center+delta]


def summary(rows):
    grouped=collections.defaultdict(list)
    for row in rows:
        grouped[(row['engine'],row['policy'])].append(row)
    groups={}
    for (engine,policy), rs in grouped.items():
        success=sum(r['score']['success'] for r in rs)
        times=sorted(r['result']['elapsed_ms'] for r in rs)
        groups[engine+'/'+policy]={'n':len(rs),'successes':success,'success_rate':success/len(rs),
            'wilson_95':wilson(success,len(rs)),'median_ms':statistics.median(times),
            'p95_ms':times[math.ceil(.95*len(times))-1], 'requests':sum(r['requests'] for r in rs),
            'input_tokens':sum(r['input_tokens'] for r in rs),'output_tokens':sum(r['output_tokens'] for r in rs),
            'estimated_usd':sum(r['estimated_usd'] for r in rs),'wrong_submissions':sum(r['score']['wrong_submissions'] for r in rs),
            'provider_ms':sum(r['provider_ms'] for r in rs),'elapsed_ms':sum(times)}
    # Bootstrap paired latency deltas by task, retaining all repeated runs per task.
    comparisons={}
    for label,left,right in [('engines_completion',('alloy','completion'),('pi','completion')),
                              ('engines_stop',('alloy','stop'),('pi','stop')),
                              ('alloy_policy',('alloy','stop'),('alloy','completion')),
                              ('pi_policy',('pi','stop'),('pi','completion')),
                              ('engines_guided',('alloy','guided_stop'),('pi','guided_stop')),
                              ('alloy_contract',('alloy','guided_stop'),('alloy','stop')),
                              ('pi_contract',('pi','guided_stop'),('pi','stop'))]:
        a={(r['task'],r['repeat']):r for r in rows if (r['engine'],r['policy'])==left}
        b={(r['task'],r['repeat']):r for r in rows if (r['engine'],r['policy'])==right}
        keys=sorted(a.keys()&b.keys())
        if not keys: continue
        bytask=collections.defaultdict(list)
        for key in keys:bytask[key[0]].append(a[key]['result']['elapsed_ms']-b[key]['result']['elapsed_ms'])
        tasks=list(bytask); rng=random.Random(20261013);boots=[]
        for _ in range(2000):
            values=[x for t in rng.choices(tasks,k=len(tasks)) for x in bytask[t]]
            boots.append(statistics.mean(values))
        boots.sort()
        comparisons[label]={'pairs':len(keys),'mean_paired_delta_ms':statistics.mean([v for vs in bytask.values() for v in vs]),
            'task_cluster_bootstrap_95_ms':[boots[49],boots[1949]],
            'left_only_success':sum(a[k]['score']['success'] and not b[k]['score']['success'] for k in keys),
            'right_only_success':sum(b[k]['score']['success'] and not a[k]['score']['success'] for k in keys)}
    return {'groups':groups,'paired_comparisons':comparisons}


def main():
    if not KEY:raise SystemExit('GEMINI_API_KEY or GOOGLE_API_KEY required')
    OUT.mkdir(exist_ok=False)
    tasks=json.loads((HERE/os.environ.get('LIVE_TASK_FILE','tasks.json')).read_text())[:int(os.environ.get('LIVE_TASK_LIMIT','12'))]
    repetitions=int(os.environ.get('LIVE_REPEATS','2'))
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    workers={e:Worker(e) for e in ['alloy','pi']}
    rng=random.Random(20261013);rows=[]
    plan=[]
    for repeat in range(repetitions):
        order=tasks.copy();rng.shuffle(order)
        for task in order:
            policies = {'contract':['stop','guided_stop'], 'confirmation':['guided_stop']}.get(os.environ.get('LIVE_EXPERIMENT'), ['completion','stop'])
            arms=[(e,p) for e in workers for p in policies];rng.shuffle(arms)
            plan.extend((repeat,task,e,p) for e,p in arms)
    manifest={'model':MODEL,'temperature':0,'thinking_budget':0,'max_output_tokens':512,'seed_for_order':20261013,'wire_json_order':'sorted keys, identical serialization for both engines',
        'experiment':os.environ.get('LIVE_EXPERIMENT','stopping'),'task_file':os.environ.get('LIVE_TASK_FILE','tasks.json'),'repetitions':repetitions,'task_count':len(tasks),'max_requests':MAX_REQUESTS,'max_estimated_usd':MAX_ESTIMATED_USD,
        'pricing_usd_per_million':{'input':.3,'cached_input':.03,'output':2.5},
        'pricing_source':'https://ai.google.dev/gemini-api/docs/pricing',
        'git_base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'hashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for pattern in ['lib/**/*.ex','benchmarks/pi-agent/live/*.py','benchmarks/pi-agent/live/*.json','benchmarks/pi-agent/live/*.exs','benchmarks/pi-agent/live/*.mjs','benchmarks/pi-agent/live/*.txt'] for p in ROOT.glob(pattern)}}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    try:
        with (OUT/'runs.jsonl').open('w') as log:
            for i,(repeat,task,engine,policy) in enumerate(plan):
                run_id=f'r{i}';RECORDS[run_id]=[]
                public_task={k:v for k,v in task.items() if k!='expected'}
                result=workers[engine].run({'task':public_task,'policy':'stop' if policy=='guided_stop' else policy,'contract':'enum' if policy=='guided_stop' else 'plain','model':MODEL,'url':f'http://127.0.0.1:{server.server_port}/{run_id}'})
                records=RECORDS[run_id]
                (OUT/(run_id+'-wire.json')).write_text(json.dumps(records,indent=2)+'\n')
                row={'run':run_id,'task':task['id'],'category':task['category'],'repeat':repeat,'engine':engine,'policy':policy,
                    'result':result,'score':score(result,task['expected']),'requests':len(records),
                    'provider_ms':sum(r.get('provider_ms',0) for r in records),
                    'input_tokens':sum(r.get('usage',{}).get('promptTokenCount',0) for r in records),
                    'output_tokens':sum(r.get('usage',{}).get('candidatesTokenCount',0)+r.get('usage',{}).get('thoughtsTokenCount',0) for r in records),
                    'estimated_usd':sum(estimate(r.get('usage',{})) for r in records)}
                rows.append(row);log.write(json.dumps(row)+'\n');log.flush()
                print(f"{i+1}/{len(plan)} {engine}/{policy} {task['id']}: {'PASS' if row['score']['success'] else 'FAIL'} {result['elapsed_ms']:.0f} ms {len(records)} requests",flush=True)
                if not records or any(r.get('http_status')!=200 for r in records):
                    raise RuntimeError('Provider/configuration failure; stop instead of treating infrastructure failures as model quality')
        report=summary(rows);(OUT/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2),flush=True)
    finally:
        for worker in workers.values():worker.close()
        server.shutdown()


if __name__=='__main__':main()
