import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
const roots=['index.html','index.motion.json','assets','scripts/create-score.mjs','scripts/create-ui-sounds.mjs','frame.md','hyperframes.json','package.json'];
const files=[];function walk(p){if(!fs.existsSync(p))return;if(fs.statSync(p).isDirectory())for(const f of fs.readdirSync(p).sort())walk(path.join(p,f));else files.push(p);}roots.forEach(walk);
const rows=files.sort().map(p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')+'  '+p);const body=rows.join('\n')+'\n';fs.writeFileSync('reports/candidate-sha256.txt',body);console.log(crypto.createHash('sha256').update(body).digest('hex'));
