#!/usr/bin/env python3
"""Reduce sampled stacks for one PID; weights are not calibrated utilization."""
import sys,json,xml.etree.ElementTree as ET
from pathlib import Path
from collections import Counter

def rank(counter,limit):
 return sorted(counter.items(),key=lambda item:(-item[1],item[0]))[:limit]


base=Path(sys.argv[1]);pid=int(sys.argv[2])
start=float(sys.argv[3]) if len(sys.argv)>3 else 5
end=float(sys.argv[4]) if len(sys.argv)>4 else 15
assert start<end
root=ET.parse(base/"time-profile.xml").getroot()
refs={e.get("id"):e for e in root.iter() if e.get("id")}
cols=[e.text for e in root.findall(".//schema/col/mnemonic")]
def resolve(e):return refs.get(e.get("ref"),e)
inclusive=Counter();leaf=Counter();own=Counter();threads=Counter();states=Counter();count=0
for row in root.findall(".//row"):
 values={k:resolve(e) for k,e in zip(cols,row)}
 proc=values["process"];child=proc.find("pid")
 if child is None or int(resolve(child).text)!=pid:continue
 t=int(values["time"].text)
 if not start*1e9<=t<end*1e9:continue
 count+=1;weight=int(values["weight"].text)
 threads[values["thread"].get("fmt")]+=weight
 states[values["thread-state"].text]+=1
 frames=[resolve(e) for e in values["stack"].findall("frame")]
 names=[e.get("name") for e in frames]
 for name in set(names):inclusive[name]+=weight
 if names:leaf[names[0]]+=weight
 for name in set(e.get("name") for e in frames if e.find("binary") is not None and resolve(e.find("binary")).get("name")=="MonolithProbe"):
  own[name]+=weight
if count==0:raise ValueError("No samples for requested PID and window")
def top_ms(counter,limit):return {name:weight/1e6 for name,weight in rank(counter,limit)}
result={"process_pid":pid,"window_seconds":[start,end],"samples":count,"states":dict(states),
 "thread_sample_weight_ms":{k:v/1e6 for k,v in threads.items()},
 "inclusive_ms":top_ms(inclusive,25),"leaf_ms":top_ms(leaf,20),"own_inclusive_ms":top_ms(own,30),
 "warning":"Sampling weights are not calibrated CPU utilization; inclusive stack costs overlap. Fixture rusage measurement has a different time anchor."}
(base/"cpu-analysis.json").write_text(json.dumps(result,indent=2))
print(json.dumps({"process_pid":pid,"samples":count,"output":str(base/"cpu-analysis.json")},indent=2))
