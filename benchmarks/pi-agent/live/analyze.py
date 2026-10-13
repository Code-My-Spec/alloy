"""Offline summaries; keep fast failures separate from successful-task latency."""
import collections
import json
import math
import random
import statistics
import sys
from pathlib import Path


def paired(rows, left, right):
    index={(r['engine'],r['policy'],r['task'],r['repeat']):r for r in rows}
    values=collections.defaultdict(list)
    for r in rows:
        if (r['engine'],r['policy'])!=left:continue
        other=index.get((*right,r['task'],r['repeat']))
        if other and r['score']['success'] and other['score']['success']:
            values[r['task']].append(r['result']['elapsed_ms']-other['result']['elapsed_ms'])
    if not values:return None
    rng=random.Random(20261013);tasks=list(values);boots=[]
    for _ in range(4000):
        boots.append(statistics.mean([v for t in rng.choices(tasks,k=len(tasks)) for v in values[t]]))
    boots.sort()
    return {'successful_pairs':sum(map(len,values.values())), 'task_clusters':len(values),
            'mean_delta_ms':statistics.mean([v for vs in values.values() for v in vs]),
            'task_cluster_bootstrap_95_ms':[boots[99],boots[3899]]}


def analyze(path):
    rows=[json.loads(line) for line in (path/'runs.jsonl').read_text().splitlines()]
    groups={}
    for engine,policy in sorted({(r['engine'],r['policy']) for r in rows}):
        rs=[r for r in rows if (r['engine'],r['policy'])==(engine,policy)]
        good=[r for r in rs if r['score']['success']]
        times=sorted(r['result']['elapsed_ms'] for r in good)
        groups[engine+'/'+policy]={'n':len(rs),'final_correct':sum(r['score']['final_correct'] for r in rs),'clean_successes':len(good),
            'successful_median_ms':statistics.median(times) if times else None,
            'successful_p95_ms':times[math.ceil(.95*len(times))-1] if times else None,
            'successful_mean_requests':statistics.mean(r['requests'] for r in good) if good else None,
            'total_estimated_usd':sum(r['estimated_usd'] for r in rs),
            'usd_per_clean_success_including_failures':sum(r['estimated_usd'] for r in rs)/len(good) if good else None,
            'provider_fraction_of_elapsed':sum(r['provider_ms'] for r in rs)/sum(r['result']['elapsed_ms'] for r in rs),
            'failures':[{'run':r['run'],'task':r['task'],'score':r['score'],'text':r['result'].get('text')} for r in rs if not r['score']['success']]}
    comparisons={}
    for label,left,right in [('engines_completion',('alloy','completion'),('pi','completion')),
                            ('engines_stop',('alloy','stop'),('pi','stop')),
                            ('engines_guided',('alloy','guided_stop'),('pi','guided_stop')),
                            ('alloy_stopping',('alloy','stop'),('alloy','completion')),
                            ('pi_stopping',('pi','stop'),('pi','completion')),
                            ('alloy_contract',('alloy','guided_stop'),('alloy','stop')),
                            ('pi_contract',('pi','guided_stop'),('pi','stop'))]:
        result=paired(rows,left,right)
        if result:comparisons[label]=result
    report={'groups':groups,'successful_paired_comparisons':comparisons,'analysis_source':str(Path(__file__).name)}
    (path/'quality-speed.json').write_text(json.dumps(report,indent=2)+'\n')
    for name,g in groups.items():
        print(name,f"{g['clean_successes']}/{g['n']}",f"{g['successful_median_ms']:.0f} ms" if g['successful_median_ms'] else 'no successes')
    return report


if __name__=='__main__':
    analyze(Path(sys.argv[1]))
