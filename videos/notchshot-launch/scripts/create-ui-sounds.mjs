import fs from 'node:fs';
function wav(name,duration,fn){const sr=44100,n=Math.ceil(sr*duration),b=Buffer.alloc(44+n*2);b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);b.writeUInt32LE(sr,24);b.writeUInt32LE(sr*2,28);b.writeUInt16LE(2,32);b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(n*2,40);let seed=117;const noise=()=>{seed=(1664525*seed+1013904223)>>>0;return seed/4294967296*2-1};for(let i=0;i<n;i++){const t=i/sr,v=Math.max(-.8,Math.min(.8,fn(t,noise)));b.writeInt16LE(Math.round(v*32767),44+i*2)}fs.writeFileSync('assets/'+name,b);}
wav('click.wav',.16,(t,n)=>.22*Math.exp(-t*75)*(Math.sin(2*Math.PI*920*t)*.6+n()*.4));
wav('shutter.wav',.32,(t,n)=>{const a=.16*Math.exp(-t*52)*n();const s=t-.085;return a+(s>0?.12*Math.exp(-s*42)*n():0)});
console.log('Original local click and shutter sounds generated.');
