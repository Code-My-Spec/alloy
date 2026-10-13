"""Diagnose one development failure by changing one wire representation at a time."""
import copy
import hashlib
import importlib.util
import json
import os
import random
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('runner',HERE/'run.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
rows=[json.loads(x) for x in (HERE/'results/runs.jsonl').read_text().splitlines()]
failed=next(r for r in rows if r['engine']=='alloy' and r['task']=='join_0')
wire=json.loads((HERE/'results'/f"{failed['run']}-wire.json").read_text())
original=wire[2]['request']
variants={}
for mode in ['original','result_envelope','omit_ids','system_and_auto','combined']:
    body=copy.deepcopy(original)
    if mode in ['result_envelope','combined']:
        for msg in body['contents']:
            for part in msg['parts']:
                if 'functionResponse' in part:
                    fr=part['functionResponse'];fr['response']={'output':json.dumps(fr['response'],separators=(',',':'),sort_keys=True)}
    if mode in ['omit_ids','combined']:
        for msg in body['contents']:
            for part in msg['parts']:
                for key in ['functionCall','functionResponse']:
                    if key in part:part[key].pop('id',None)
    if mode in ['system_and_auto','combined']:
        body['systemInstruction']['role']='user';body.pop('toolConfig',None)
    variants[mode]=body
out=HERE/'ablation-results';out.mkdir(exist_ok=False)
plan=[(rep,mode) for rep in range(3) for mode in variants];random.Random(20261013).shuffle(plan)
key=os.environ.get('GEMINI_API_KEY') or os.environ['GOOGLE_API_KEY']
results=[]
for rep,mode in plan:
    body=variants[mode];start=time.perf_counter()
    req=urllib.request.Request('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',data=json.dumps(body,sort_keys=True,separators=(',',':')).encode(),headers={'x-goog-api-key':key,'Content-Type':'application/json'})
    response=json.load(urllib.request.urlopen(req,timeout=35))
    parts=response.get('candidates',[{}])[0].get('content',{}).get('parts',[])
    calls=[p['functionCall'] for p in parts if 'functionCall' in p]
    correct=bool(calls) and all(c['name']=='calculate' and c.get('args',{}).get('op')=='multiply' and {c['args'].get('a'),c['args'].get('b')} in [{137,29},{7,53}] for c in calls)
    row={'repeat':rep,'variant':mode,'request':body,'response':response,'correct_tool':correct,'elapsed_ms':(time.perf_counter()-start)*1000,'estimated_usd':runner.estimate(response.get('usageMetadata',{}))}
    results.append(row);(out/'runs.json').write_text(json.dumps(results,indent=2)+'\n')
    print(mode,rep,'PASS' if correct else 'FAIL',[c.get('name') for c in calls],flush=True)
