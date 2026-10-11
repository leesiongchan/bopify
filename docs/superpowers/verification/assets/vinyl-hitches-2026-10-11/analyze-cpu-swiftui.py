import sys,json,statistics,math,xml.etree.ElementTree as ET
from pathlib import Path
from collections import Counter,defaultdict

def rank(counter,limit):
 return sorted(counter.items(),key=lambda item:(-item[1],item[0]))[:limit]

rootdir=Path(sys.argv[1]); pid=int(sys.argv[2]); START=int(float(sys.argv[3] if len(sys.argv)>3 else 2)*1e9);END=int(float(sys.argv[4] if len(sys.argv)>4 else 12)*1e9)

def load(name):
 root=ET.parse(rootdir/name).getroot();refs={e.get("id"):e for e in root.iter() if e.get("id")}
 cols=[e.text for e in root.findall(".//schema/col/mnemonic")]
 def res(e):return refs.get(e.get("ref"),e)
 rows=[]
 for row in root.findall(".//row"):
  vals={c:res(e) for c,e in zip(cols,row)}
  proc=vals.get("process");proc_pid=res(proc.find("pid")) if proc is not None and proc.find("pid") is not None else None
  if proc_pid is not None and int(proc_pid.text)!=pid:continue
  rows.append(vals)
 return rows,res

def val(e):return e.text if e is not None and e.text is not None else (e.get("fmt") if e is not None else None)
def dist(vals):
 vals=sorted(vals)
 return {"count":len(vals),"total_ms":sum(vals),"median_ms":statistics.median(vals),"p95_ms":vals[min(len(vals)-1,math.ceil(.95*len(vals))-1)],"max_ms":max(vals)} if vals else {"count":0}

def top(counter,n=20):return [{"name":k,"weighted_ms":v/1e6} for k,v in rank(counter,n)]
rows,res=load("hitches.xml")
hitches=[r for r in rows if START<=int(val(r["start"]))<END and val(r["is-system"])=="0"]
hranges=[(int(val(r["start"])),int(val(r["start"]))+int(val(r["duration"]))) for r in hitches]
result={"process_pid":pid,"window_seconds":[START/1e9,END/1e9],"hitches":dist([int(val(r["duration"]))/1e6 for r in hitches]),"hitch_narratives":dict(Counter(val(r["narrative-description"]) or "unspecified" for r in hitches))}
rows,res=load("time-profile.xml")
cpus=[r for r in rows if START<=int(val(r["time"]))<END]
thread=Counter();inclusive=Counter();leaf=Counter();ownincl=Counter();ownleaf=Counter();hincl=Counter();hincl_own=Counter();trace_weight=0;maintraceweight=0;hmainweight=0;hmainsamples=0
for r in cpus:
 weight=int(val(r["weight"]));tid=r["thread"].get("fmt");thread[tid]+=weight
 stack=r["stack"];frames=[res(e) for e in stack.findall("frame")];names=[e.get("name") for e in frames];bins=[res(e.find("binary")).get("name") if e.find("binary") is not None else None for e in frames]
 for name in set(names):inclusive[name]+=weight
 if names:leaf[names[0]]+=weight
 own=set(n for n,b in zip(names,bins) if b=="MonolithProbe")
 for name in own:ownincl[name]+=weight
 if names and bins[0]=="MonolithProbe":ownleaf[names[0]]+=weight
 istrace="SwiftUITracingSupport" in bins
 if istrace:trace_weight+=weight
 main=tid.startswith("Main Thread")
 if main and istrace:maintraceweight+=weight
 t=int(val(r["time"]))
 if main and any(a<=t<b for a,b in hranges):
  hmainweight+=weight;hmainsamples+=1
  for name in set(names):hincl[name]+=weight
  for name in own:hincl_own[name]+=weight
result["cpu"]={"sample_weight_limit":"Sampling weights are not calibrated CPU utilization; inclusive stack costs overlap.","samples":len(cpus),"thread_states":dict(Counter(val(r["thread-state"]) for r in cpus)),"sample_weight_total_ms":sum(thread.values())/1e6,"main_weight_ms":sum(v for k,v in thread.items() if k.startswith("Main Thread"))/1e6,"main_sample_weight_window_percent":sum(v for k,v in thread.items() if k.startswith("Main Thread"))/(END-START)*100,"thread_weight_ms":{k:v/1e6 for k,v in thread.items()},"trace_support_inclusive_ms":trace_weight/1e6,"main_trace_support_inclusive_ms":maintraceweight/1e6,"inclusive":top(inclusive),"leaf":top(leaf),"own_inclusive":top(ownincl,35),"own_leaf":top(ownleaf,35),"hitch_main_samples":hmainsamples,"hitch_main_weight_ms":hmainweight/1e6,"hitch_inclusive":top(hincl),"hitch_own_inclusive":top(hincl_own)}
cpu_points=[(int(val(r["time"])),int(val(r["weight"]))) for r in cpus if r["thread"].get("fmt","").startswith("Main Thread")]
rows,res=load("swiftui-updates.xml");su=[r for r in rows if START<=int(val(r["start"]))<END];bydesc=defaultdict(list);byview=defaultdict(list)
for r in su:
 d=int(val(r["duration"]))/1e6
 bydesc[val(r["description"])].append(d)
 byview[(val(r["module"]),val(r["view-name"]),val(r["update-type"]))].append(d)
result["swiftui"]={"all_update_intervals":dist([int(val(r["duration"]))/1e6 for r in su]),"update_types":dict(Counter(val(r["update-type"]) for r in su)),"severity":dict(Counter(val(r["severity"]) for r in su)),"modules":dict(Counter(val(r["module"]) for r in su)),"top_descriptions_by_sum":[{"description":k,**dist(v)} for k,v in sorted(bydesc.items(),key=lambda kv:sum(kv[1]),reverse=True)[:20]],"top_views_by_sum":[{"module":k[0],"view":k[1],"type":k[2],**dist(v)} for k,v in sorted(byview.items(),key=lambda kv:sum(kv[1]),reverse=True)[:20]],"long_updates":[{"start_s":int(val(r["start"]))/1e9,"duration_ms":int(val(r["duration"]))/1e6,"type":val(r["update-type"]),"description":val(r["description"]),"view":val(r["view-name"]),"module":val(r["module"]),"severity":val(r["severity"])} for r in sorted(su,key=lambda r:int(val(r["duration"])),reverse=True)[:25]]}
rows,res=load("hitches-updates.xml");up=[r for r in rows if START<=int(val(r["start"]))<END and val(r["containment-level"])=="0"]
result["app_update_commits"]={"all":dist([int(val(r["duration"]))/1e6 for r in up]),"by_display":{d:dist([int(val(r["duration"]))/1e6 for r in up if val(r["display"])==d]) for d in sorted(set(val(r["display"]) for r in up))},"longest":[{"start_s":int(val(r["start"]))/1e9,"duration_ms":int(val(r["duration"]))/1e6,"display":val(r["display"])} for r in sorted(up,key=lambda r:int(val(r["duration"])),reverse=True)[:15]]}
long_commits=[r for r in up if int(val(r["duration"]))>10_000_000]
relative_cpu=Counter();long_cpu=[]
for r in long_commits:
 a=int(val(r["start"]));b=a+int(val(r["duration"]))
 points=[(t,w) for t,w in cpu_points if a<=t<b]
 for t,w in points:relative_cpu[(t-a)//1_000_000]+=w
 long_cpu.append({"start_s":a/1e9,"duration_ms":(b-a)/1e6,"main_sampled_weight_ms":sum(w for t,w in points)/1e6,"sample_relative_ms":[round((t-a)/1e6,6) for t,w in points]})
result["long_commit_cpu"]={"threshold_ms":10,"count":len(long_commits),"total_main_sampled_weight_ms":sum(r["main_sampled_weight_ms"] for r in long_cpu),"relative_cpu_histogram_ms":{str(k):v/1e6 for k,v in sorted(relative_cpu.items())},"per_commit":long_cpu}
(rootdir/"cpu-swiftui-analysis.json").write_text(json.dumps(result,indent=2))
print(json.dumps({"cpu":{k:v for k,v in result["cpu"].items() if k not in ("inclusive","leaf","own_leaf","hitch_inclusive","hitch_own_inclusive")},"hitches":result["hitches"],"hitch_narratives":result["hitch_narratives"],"swiftui_long_updates":result["swiftui"]["long_updates"][:7],"swiftui_views":result["swiftui"]["top_views_by_sum"][:8],"commits":result["app_update_commits"]["all"],"cpu_leaf":result["cpu"]["leaf"][:10],"hitch_inclusive":result["cpu"]["hitch_inclusive"][:10]},indent=2))
