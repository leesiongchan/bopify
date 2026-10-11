import sys,json,statistics,xml.etree.ElementTree as ET
from pathlib import Path
from collections import Counter

def rank(counter,limit):
 return sorted(counter.items(),key=lambda item:(-item[1],item[0]))[:limit]

base=Path(sys.argv[1]);pid=int(sys.argv[2]);START=5_000_000_000;END=15_000_000_000

def load(name):
 root=ET.parse(base/name).getroot();refs={e.get("id"):e for e in root.iter() if e.get("id")};cols=[e.text for e in root.findall(".//schema/col/mnemonic")]
 def res(e):return refs.get(e.get("ref"),e)
 rows=[]
 for row in root.findall(".//row"):
  d={c:res(e) for c,e in zip(cols,row)};proc=d.get("process");child=proc.find("pid") if proc is not None else None
  if child is not None and int(res(child).text)==pid:rows.append(d)
 return rows,res

def val(e):return e.text if e is not None and e.text is not None else e.get("fmt") if e is not None else None
rows,res=load("time-profile.xml");samples=[];all_process_points=[];eventleaf=Counter();eventincl=Counter();eventlines=Counter();eventstacks=Counter()
for r in rows:
 t=int(val(r["time"]))
 if not START<=t<END:continue
 all_process_points.append((t,int(val(r["weight"]))))
 if not r["thread"].get("fmt","").startswith("Main Thread"):continue
 w=int(val(r["weight"]));fs=[res(e) for e in r["stack"].findall("frame")];names=[e.get("name") for e in fs]
 own=set(e.get("name") for e in fs if e.find("binary") is not None and res(e.find("binary")).get("name")=="MonolithProbe")
 samples.append((t,w,names,own))
 if any("StatusPanel.sendEvent" in n or "PlayerHostingView.mouse" in n for n in names):
  if names:eventleaf[names[0]]+=w;eventstacks[tuple(names[:7])]+=w
  for n in set(names):eventincl[n]+=w
  if fs:
   e=fs[0];src=e.find("source")
   if src is not None:eventlines[(e.get("name"),src.get("line"))]+=w
samples.sort(key=lambda sample:sample[0]);all_process_points.sort(key=lambda sample:sample[0])
rows,res=load("swiftui-updates.xml");long=[];motor=[];progress=[];all500=0
for r in rows:
 a=int(val(r["start"]));d=int(val(r["duration"]));desc=val(r["description"])
 if not START<=a<END:continue
 if desc=="DynamicBody<ViewBodyAccessor<MorphingArtworkView>, MainThreadFlags>":motor.append(a)
 if desc=="DynamicBody<ViewBodyAccessor<RadialProgressView>, MainThreadFlags>":progress.append(a)
 if d<=500_000:continue
 all500+=1;points=[s for s in samples if a<=s[0]<a+d];leaf=Counter();own=Counter()
 for t,w,n,o in points:
  if n:leaf[n[0]]+=w
  for k in o:own[k]+=w
 pts=[a]+[t for t,w,n,o in points]+[a+d]
 long.append({"start_s":a/1e9,"duration_ms":d/1e6,"description":desc,"severity":val(r["severity"]),"main_sample_count":len(points),"main_sample_weight_ms":sum(s[1] for s in points)/1e6,"max_main_sample_gap_ms":max(y-x for x,y in zip(pts,pts[1:]))/1e6,"sample_relative_ms":[round((s[0]-a)/1e6,5) for s in points],"leaf_weight_ms":{k:v/1e6 for k,v in rank(leaf,8)},"own_inclusive_weight_ms":{k:v/1e6 for k,v in rank(own,8)}})
motor.sort();progress.sort()
bodygaps={k:[{"start_s":a/1e9,"end_s":b/1e9,"duration_ms":(b-a)/1e6} for a,b in zip(ts,ts[1:]) if b-a>100_000_000] for k,ts in [("motor_child",motor),("progress",progress)]}
for gaps in bodygaps.values():
 for gap in gaps:
  a=round(gap["start_s"]*1e9);b=round(gap["end_s"]*1e9);points=[s for s in samples if a<=s[0]<b];leaf=Counter();own=Counter()
  for t,w,n,o in points:
   if n:leaf[n[0]]+=w
   for k in o:own[k]+=w
  gap["main_sample_count"]=len(points);gap["main_sample_weight_ms"]=sum(s[1] for s in points)/1e6;gap["all_process_sample_weight_ms"]=sum(w for t,w in all_process_points if a<=t<b)/1e6
  times=[a]+[s[0] for s in points]+[b];gap["max_main_sample_gap_ms"]=max(y-x for x,y in zip(times,times[1:]))/1e6
  gap["main_leaf_weight_ms"]={k:v/1e6 for k,v in rank(leaf,5)};gap["own_inclusive_weight_ms"]={k:v/1e6 for k,v in rank(own,8)}
result={"process_pid":pid,"window_seconds":[5,15],"swiftui_intervals_over500us_count":all500,"long_intervals":sorted(long,key=lambda r:r["duration_ms"],reverse=True),"body_evaluation_gaps_over100ms":bodygaps,"event_ancestry":{"leaf_weight_ms":{k:v/1e6 for k,v in rank(eventleaf,20)},"inclusive_weight_ms":{k:v/1e6 for k,v in rank(eventincl,30)},"leaf_source_weight_ms":[{"name":k[0],"line":k[1],"weight_ms":v/1e6} for k,v in rank(eventlines,10)],"top_leaf_stacks":[{"frames":list(k),"weight_ms":v/1e6} for k,v in rank(eventstacks,8)]},"limits":["Long SwiftUI interval wall time is not CPU self-time.","Sample gaps cannot distinguish idle, scheduler delay, missed samples or tracing overhead without scheduler data.","Fixture monotonic tick gaps have no exact trace anchor; matching body-gap patterns is only approximate correlation.","Inclusive stack weights overlap and are not calibrated utilization."]}
(base/"long-swiftui-analysis.json").write_text(json.dumps(result,indent=2))
print(json.dumps({"long_intervals_count":all500,"longest":[{k:v for k,v in r.items() if k!="sample_relative_ms"} for r in result["long_intervals"][:7]],"bodygaps":bodygaps,"eventleaf":result["event_ancestry"]["leaf_weight_ms"],"eventstacks":result["event_ancestry"]["top_leaf_stacks"][:3]},indent=2))
