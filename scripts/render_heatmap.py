#!/usr/bin/env python3
"""Render supplied directed measurements as a portable SVG; no invented cells."""
import csv,html,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]) if len(sys.argv)>1 else root/'evidence/cross-leaf-summary-2026-09-30.tsv'
dest=Path(sys.argv[2]) if len(sys.argv)>2 else root/'diagrams/cross-leaf-partial-heatmap.svg'
hosts=['weka68','weka60','weka49','weka40']
leaf={h:f'leaf-{i+1:02}' for i,h in enumerate(hosts)}
rows=list(csv.DictReader(source.open(),delimiter='\t')); data={(r['SOURCE'],r['DESTINATION']):r for r in rows}
svg=['<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="850" viewBox="0 0 1120 850">',
 '<rect width="1120" height="850" fill="#f5f8fa"/>',
 '<style>text{font-family:Arial,sans-serif} .label{font-size:16px;fill:#183747} .note{font-size:14px;fill:#4b6473}</style>']
def text(x,y,t,size=16,fill='#183747',anchor='start'):
    svg.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" text-anchor="{anchor}">{html.escape(t)}</text>')
text(40,50,'Production SN5600 / WEKA — cross-leaf RDMA',28)
text(40,82,f'Partial evidence: {len(data)} of 12 directed pairs supplied · September 30, 2026',17)
text(40,112,'Two NICs concurrently · 30 seconds per direction · combined bandwidth in Gbit/s',16)
left=240; top=190; w=200;h=105
text(40,170,'Source ↓ / Destination →',15)
for j,d in enumerate(hosts):
    text(left+j*w+w/2,160,f'{leaf[d]} / {d}',16,anchor='middle')
for i,s in enumerate(hosts):
    text(40,top+i*h+50,f'{leaf[s]} / {s}',16)
    for j,d in enumerate(hosts):
        r=data.get((s,d));x=left+j*w;y=top+i*h
        color='#e8eef2';ink='#506675'
        if r and r['RESULT'].startswith('COMPLETED'):
            cap=400 if 'weka68' in (s,d) else 800
            ratio=min(1,max(0,float(r['COMBINED_Gbps'])/cap))
            a=(232,242,245);b=(15,94,121)
            color='#'+''.join(f'{round(a[k]+(b[k]-a[k])*ratio):02x}' for k in range(3));ink='white' if ratio>.65 else '#183747'
        svg.append(f'<rect x="{x+4}" y="{y+4}" width="{w-8}" height="{h-8}" rx="8" fill="{color}"/>')
        if s==d:text(x+w/2,y+52,'Same leaf',17,ink,'middle')
        elif not r:text(x+w/2,y+52,'Not yet supplied',16,ink,'middle')
        elif not r['RESULT'].startswith('COMPLETED'):text(x+w/2,y+52,'Test failed',17,'#992a28','middle')
        else:
            text(x+w/2,y+42,r['COMBINED_Gbps'],26,ink,'middle')
            text(x+w/2,y+66,f"NICs: {r['MLX5_0_Gbps']} + {r['MLX5_1_Gbps']}",12,ink,'middle')
            if 'WARNING' in r['RESULT']:text(x+w/2,y+86,'Server-log collection warning',11,ink,'middle')
text(40,650,'Color shows throughput relative to the slower endpoint’s nominal combined link rate.',15)
text(40,678,'leaf-01: 2 × 200G; other representatives: 2 × 400G. Darker blue = higher relative throughput.',15)
text(40,716,'Scope: representative client paths; not every ECMP link, all clients, congestion or failover.',15)
text(40,744,'weka68 → weka40: client benchmarks returned 0/0; SSH server-log retrieval failed.',15)
text(40,772,'Unmeasured cells are left blank of bandwidth values. Do not infer reverse-direction results.',15)
svg.append('</svg>');dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text('\n'.join(svg)+'\n')
print(dest)
