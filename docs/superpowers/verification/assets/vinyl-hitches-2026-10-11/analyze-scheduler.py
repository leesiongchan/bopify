import json,sys,xml.etree.ElementTree as ET
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
  fields={k:res(e) for k,e in zip(cols,row)}
  process=fields.get("process")
  process_pid=process.find("pid") if process is not None else None
  if process_pid is None or int(res(process_pid).text)!=pid:continue
  rows.append(fields)
 return rows,res

def val(e):return e.text if e is not None and e.text is not None else e.get("fmt") if e is not None else None
def tid(e,res):return int(val(res(e.find("tid"))))
def union(ranges):
 out=[]
 for a,b in sorted(ranges):
  a=max(START,a);b=min(END,b)
  if b<=a:continue
  if out and a<=out[-1][1]:out[-1]=(out[-1][0],max(out[-1][1],b))
  else:out.append((a,b))
 return out
def overlap(a,b,ranges):return sum(max(0,min(b,y)-max(a,x)) for x,y in ranges)
rows,res=load("time-profile.xml")
main_tids=set(tid(r["thread"],res) for r in rows if r["thread"].get("fmt","").startswith("Main Thread"));assert len(main_tids)==1;MAIN=main_tids.pop()
rows,res=load("hitches-updates.xml")
long=[r for r in rows if val(r["containment-level"])=="0" and val(r["display"])=="Display 3" and START<=int(val(r["start"]))<END and int(val(r["duration"]))>10_000_000]
longranges=union([(int(val(r["start"])),int(val(r["start"]))+int(val(r["duration"]))) for r in long])
rows,res=load("hitches.xml");hitches=[r for r in rows if val(r["is-system"])=="0" and START<=int(val(r["start"]))<END];hit_ranges=union([(int(val(r["start"])),int(val(r["start"]))+int(val(r["duration"]))) for r in hitches])
rows,res=load("thread-state.xml");states=[];made_runnable=Counter()
for r in rows:
 if tid(r["thread"],res)!=MAIN:continue
 a=int(val(r["start"]));b=a+int(val(r["duration"]));state=val(r["state"])
 states.append((a,b,state))
 if state=="Runnable" and START<=a<END:
  source=r["made-runnable-by-thread"]
  made_runnable[source.get("fmt") or source.tag]+=1
state_results={}
for scope,ranges in [("whole_window",[(START,END)]),("long_update_markers_union",longranges),("hitch_ranges_union",hit_ranges)]:
 c=Counter()
 for a,b,s in states:c[s]+=overlap(a,b,ranges)
 state_results[scope]={"scope_union_ms":sum(b-a for a,b in ranges)/1e6,"state_ms":{k:v/1e6 for k,v in c.items()},"coverage_ms":sum(c.values())/1e6}
rows,res=load("context-switch-sample.xml");samples=[]
for r in rows:
 if tid(r["thread"],res)!=MAIN or val(r["thread-state"])!="Blocked":continue
 fs=[res(e).get("name") for e in r["backtrace"].findall("frame")]
 if not fs:continue
 t=int(val(r["time"]))
 if "__CFRunLoopServiceMachPort" in fs:kind="CFRunLoop idle Mach port wait"
 elif any("fsync"==n for n in fs):kind="Fixture output fsync"
 elif any("run_query" in n for n in fs):kind="WindowServer ordering query"
 elif any("semaphore" in n for n in fs):kind="Semaphore wait"
 elif any("lock" in n.lower() and "BlockUntil" not in n for n in fs):kind="Lock wait (inspect frames)"
 else:kind="Other blocked stack"
 samples.append((t,kind,fs))
samples.sort();matched=[];unmatched=[]
for a,b,s in states:
 if s!="Blocked" or not overlap(a,b,[(START,END)]):continue
 if not samples:unmatched.append((a,b));continue
 t,kind,fs=min(samples,key=lambda e:abs(e[0]-a))
 if abs(t-a)>100_000:unmatched.append((a,b));continue
 matched.append((a,b,kind,fs,t-a))
blocked_results={}
for scope,ranges in [("whole_window",[(START,END)]),("long_update_markers_union",longranges),("hitch_ranges_union",hit_ranges)]:
 c=Counter();counts=Counter();heads=Counter()
 for a,b,k,fs,dt in matched:
  ns=overlap(a,b,ranges)
  if ns:c[k]+=ns;counts[k]+=1;heads[tuple(fs[:7])]+=ns
 un=sum(overlap(a,b,ranges) for a,b in unmatched)
 blocked_results[scope]={"blocked_category_ms":{k:v/1e6 for k,v in c.items()},"blocked_interval_counts":dict(counts),"unmatched_blocked_ms":un/1e6,"top_stack_heads":[{"frames":list(k),"blocked_ms":v/1e6} for k,v in rank(heads,5)]}
perlong=[]
for a,b in longranges:
 c=Counter()
 for x,y,s in states:c[s]+=overlap(x,y,[(a,b)])
 perlong.append({"start_s":a/1e9,"duration_ms":(b-a)/1e6,"state_ms":{k:v/1e6 for k,v in c.items()}})
first_marker=min(long,key=lambda r:int(val(r["start"]))) if long else None
first_marker_states=[]
if first_marker is not None:
 first_start=int(val(first_marker["start"]));first_end=first_start+int(val(first_marker["duration"]))
 first_marker_states=[{"start_s":a/1e9,"end_s":b/1e9,"state":s} for a,b,s in states if b>first_start and a<first_end]
result={"process_pid":pid,"main_runnable_made_by_counts":dict(made_runnable),"first_long_marker_scheduler_intervals":first_marker_states,"main_tid":MAIN,"window_seconds":[5,15],"long_update_marker_threshold_ms":10,"long_top_level_display3_marker_count":len(long),"hitch_count":len(hitches),"states":state_results,"blocked_stacks":blocked_results,"state_interval_count":len(states),"matched_blocked_intervals":len(matched),"matched_sample_delta_max_us":max(abs(e[4])/1000 for e in matched),"long_marker_union_values":perlong,"limits":["Thread states quantify scheduler time; update marker intervals may include idle time.","Blocked stack matched to interval start within100us; no frame-specific provenance inferred.","Fixture fsync is verification output, not production I/O."]}
(base/"scheduler-analysis.json").write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k not in ["long_marker_union_values","blocked_stacks"]},indent=2));print(json.dumps({k:{a:b for a,b in v.items() if a!="top_stack_heads"} for k,v in blocked_results.items()},indent=2))
